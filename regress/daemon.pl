#!/usr/bin/perl

# Uninitialized start, config check, background title, and SIGHUP.
# Uses -d and -c on a temp directory. Does not create /var/sl or
# read /etc/sl.conf.

use strict;
use warnings;
use File::Path qw(remove_tree);
use FindBin;
use IO::Socket::INET;

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../blib";
use SLMON ();
use SLMON::Config;
use SLMON::DB;
use SLMON::Parent;

my $root = "$FindBin::Bin/..";
chdir $root or die "chdir $root: $!";
my $work = "/tmp/slmon-daemon-$$";
mkdir $work, 0700 or die "mkdir $work: $!";
my $had_var_sl = -d '/var/sl';
my $parent_pid = 0;
my $starter_pid = 0;

sub dump_logs {
	for my $name ('uninit.err', 'bad.err', 'low.err', 'pty.err',
	    'passwd.err', 'init2.out', 'sld.out', 'sld.err') {
		my $path = "$work/$name";
		next if !-f $path;
		print STDERR "----- $name -----\n";
		open my $fh, '<', $path or next;
		local $/;
		my $text = <$fh> // '';
		close $fh;
		print STDERR substr($text, -4000);
	}
	return;
}

END {
	my $failed = $?;
	if ($starter_pid && kill 0, $starter_pid) {
		kill 'TERM', $starter_pid;
		waitpid $starter_pid, 0;
	}
	if ($parent_pid && kill 0, $parent_pid) {
		kill 'TERM', $parent_pid;
		my $deadline = time + 8;
		while (time < $deadline && kill 0, $parent_pid) {
			select undef, undef, undef, 0.1;
		}
		kill 'KILL', $parent_pid if kill 0, $parent_pid;
	}
	dump_logs() if $failed;
	remove_tree($work) if $work && -d $work && !$ENV{SLMON_KEEP_E2E};
}

sub write_file {
	my ($path, $text) = @_;
	open my $fh, '>', $path or die "$path: $!";
	print $fh $text or die "$path: $!";
	close $fh or die "$path: $!";
	return;
}

sub run_capture {
	my (@cmd) = @_;
	my $pid = open my $fh, '-|';
	die "fork: $!" if !defined $pid;
	if ($pid == 0) {
		open STDERR, '>&', \*STDOUT or exit 127;
		exec @cmd or exit 127;
	}
	local $/;
	my $out = <$fh>;
	$out = '' if !defined $out;
	close $fh;
	return ($?, $out);
}

sub pids_exact {
	my ($title) = @_;
	my @pids;
	open my $pg, '-|', 'pgrep', '-xf', $title or return ();
	while (my $line = <$pg>) {
		chomp $line;
		push @pids, $line if $line =~ /\A\d+\z/;
	}
	close $pg;
	return @pids;
}

sub same_pids {
	my ($a, $b) = @_;
	return join(',', sort @$a) eq join(',', sort @$b);
}

sub wait_port_file {
	my ($path, $want, $seconds) = @_;
	my $deadline = time + $seconds;
	while (time < $deadline) {
		if (open my $fh, '<', $path) {
			my $line = <$fh>;
			close $fh;
			if (defined $line && $line =~ /(\d+)/) {
				my $port = $1;
				next if defined $want && $port != $want;
				my $sock = IO::Socket::INET->new(
					PeerAddr => '127.0.0.1',
					PeerPort => $port,
					Proto    => 'tcp',
					Timeout  => 1,
				);
				return $port if $sock;
			}
		}
		select undef, undef, undef, 0.1;
	}
	die "timed out waiting for $path\n";
}

sub http_code {
	my ($port) = @_;
	my $sock = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => 2,
	);
	return 0 if !$sock;
	syswrite $sock, "GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
	local $/;
	my $resp = <$sock> // '';
	my ($code) = $resp =~ /\AHTTP\/\S+\s+(\d+)/;
	return $code // 0;
}

sub dish_pid {
	my ($path) = @_;
	open my $fh, '<', $path or return 0;
	my $pid = 0;
	while (my $line = <$fh>) {
		$pid = $1 if $line =~ /start (\d+)/;
	}
	close $fh;
	return $pid;
}

sub wait_dish_pid {
	my ($path, $old, $seconds) = @_;
	my $deadline = time + $seconds;
	while (time < $deadline) {
		my $pid = dish_pid($path);
		return $pid if $pid && $pid != $old && !kill(0, $old);
		select undef, undef, undef, 0.1;
	}
	die "dish pid did not change from $old\n";
}

sub admin_settings {
	my ($db) = @_;
	my $cfg = SLMON::Config::parse("db = sqlite\n");
	SLMON::Config::apply_paths($cfg, db_path => $db);
	my $dbh = SLMON::DB::open_db($cfg, readonly => 1);
	my $row = SLMON::DB::settings($dbh);
	$dbh->disconnect;
	return $row || {};
}

sub admin_hash {
	my ($db) = @_;
	my $row = admin_settings($db);
	return $row->{admin_pass_hash} ? $row->{admin_pass_hash} : '';
}

sub log_grew {
	my ($needle, $marks) = @_;
	for my $path (keys %$marks) {
		next if !defined $marks->{$path};
		next if !-r $path;
		open my $fh, '<', $path or next;
		seek $fh, $marks->{$path}, 0;
		local $/;
		my $text = <$fh> // '';
		close $fh;
		return 1 if index($text, $needle) >= 0;
	}
	return 0;
}

my $missing = "$work/missing.db";
my @parents = pids_exact('sld: parent');
my ($st, $out) = run_capture($^X, "$root/bin/sld", '-d', $missing);
die "uninit exit status $st\n[$out]\n" if $st == 0;
my $expect = "sld: $missing is not initialized\nsld: doas -u _sl slctl init\n";
die "uninit text:\n[$out]\n" if $out ne $expect;
die "uninit created $missing\n" if -e $missing;
my @parents_after = pids_exact('sld: parent');
die "uninit left a parent\n" if !same_pids(\@parents, \@parents_after);

write_file("$work/bad.conf", "nope = 1\n");
($st, $out) = run_capture($^X, "$root/bin/sld", '-n', '-c', "$work/bad.conf",
    '-d', $missing);
die "bad key status $st\n[$out]\n" if $st == 0;
die "bad key text:\n[$out]\n" if $out !~ /\Asld: unknown config key nope\n/;

write_file("$work/low.conf", "listen = 127.0.0.1:80\n");
($st, $out) = run_capture($^X, "$root/bin/sld", '-n', '-c', "$work/low.conf",
    '-d', $missing);
die "low port status $st\n[$out]\n" if $st == 0;
die "low port text:\n[$out]\n"
    if $out !~ /\Asld: listen port must be 0 or at least 1024\n/;

my $refused = SLMON::Parent::init_refused(0);
die "root init line [$refused]\n"
    if ($refused // '') ne 'slctl: doas -u _sl slctl init';
die "non-root init was refused\n" if defined SLMON::Parent::init_refused(1);
my $prefused = SLMON::Parent::init_refused(0, 'passwd');
die "root passwd line [$prefused]\n"
    if ($prefused // '') ne 'slctl: doas -u _sl slctl passwd';
die "non-root passwd was refused\n" if defined SLMON::Parent::init_refused(1, 'passwd');

my $db = "$work/sl.db";
my $other = "$work/other.db";
my $log = "$work/fake.log";
write_file($log, '');
my $conf = "$work/sl.conf";
write_file($conf, <<"END");
db = sqlite
db_path = $db
listen = 127.0.0.1:0
dish_host = 127.0.0.1
dish_interval_s = 30
log_level = info
rollup_interval_s = 60
ping_targets = 127.0.0.1
ping_interval_s = 30
disconnect_failures = 3
spike_ms = 200
spike_min_s = 30
END
write_file("$work/prompt.script", <<'END');
W Admin user
S
W Password:
S regress-secret
W Repeat password:
S regress-secret
END
write_file("$work/passwd.script", <<'END');
W Admin user
S operator
W Password:
S new-secret
W Repeat password:
S new-secret
W admin user reset
W rcctl restart sld
END

my $absent = "$work/absent.db";
($st, $out) = run_capture($^X, "$root/bin/slctl", 'passwd', '-c', $conf, '-d', $absent);
die "passwd on a missing database status $st\n[$out]\n" if $st == 0;
die "passwd missing text:\n[$out]\n"
    if $out ne "slctl: $absent is not initialized\nslctl: doas -u _sl slctl init\n";
die "passwd created $absent\n" if -e $absent;

$ENV{SLMON_DISH_CMD} = "$root/regress/fakedish.pl";
$ENV{SLMON_FAKE_LOG} = $log;
$ENV{PERL5LIB} = "$root/lib:$root/blib";

pipe(my $out_r, my $out_w) or die "pipe: $!";
pipe(my $in_r, my $in_w) or die "pipe: $!";
my $pty_pid = fork();
die "fork: $!" if !defined $pty_pid;
if ($pty_pid == 0) {
	close $out_r;
	close $in_w;
	open STDIN, '<&', $in_r or die "stdin: $!";
	open STDOUT, '>&', $out_w or die "stdout: $!";
	open STDERR, '>', "$work/pty.err" or die "stderr: $!";
	exec "$root/regress/ptyfeed", "$work/prompt.script",
	    $^X, "$root/bin/slctl", 'init', '-c', $conf, '-d', $db;
	die "exec ptyfeed: $!";
}
close $out_w;
close $in_r;
my $pid_line = <$out_r>;
die "ptyfeed did not report a pid\n" if !defined $pid_line || $pid_line !~ /PID\s+(\d+)/;
print $in_w "QUIT\n";
close $in_w;
waitpid $pty_pid, 0;
$st = $?;
die "init exit status $st\n" if $st != 0;
die "init did not create $db\n" if !-f $db;
my $hash = admin_hash($db);
die "init stored no password\n" if $hash eq '';

($st, $out) = run_capture($^X, "$root/bin/slctl", 'init', '-c', $conf, '-d', $db);
die "second init status $st\n[$out]\n" if $st != 0;
die "second init text:\n[$out]\n" if $out !~ /slctl: already initialized\n/;
my $hash2 = admin_hash($db);
die "second init changed the password\n" if $hash2 ne $hash;

my $before = admin_settings($db);
pipe(my $pw_r, my $pw_w) or die "pipe: $!";
pipe(my $pwin_r, my $pwin_w) or die "pipe: $!";
my $pw_pid = fork();
die "fork: $!" if !defined $pw_pid;
if ($pw_pid == 0) {
	close $pw_r;
	close $pwin_w;
	open STDIN, '<&', $pwin_r or die "stdin: $!";
	open STDOUT, '>&', $pw_w or die "stdout: $!";
	open STDERR, '>', "$work/passwd.err" or die "stderr: $!";
	exec "$root/regress/ptyfeed", "$work/passwd.script",
	    $^X, "$root/bin/slctl", 'passwd', '-c', $conf, '-d', $db;
	die "exec ptyfeed: $!";
}
close $pw_w;
close $pwin_r;
my $pw_line = <$pw_r>;
die "passwd ptyfeed did not report a pid\n" if !defined $pw_line || $pw_line !~ /PID\s+(\d+)/;
print $pwin_w "QUIT\n";
close $pwin_w;
waitpid $pw_pid, 0;
$st = $?;
close $pw_r;
die "passwd exit status $st\n" if $st != 0;
my $after = admin_settings($db);
die "passwd kept the user\n" if ($after->{admin_user} // '') ne 'operator';
die "passwd kept the password\n" if ($after->{admin_pass_hash} // '') eq $hash;
die "passwd kept the session key\n"
    if ($after->{session_secret} // '') eq ($before->{session_secret} // '');
die "old password still matches\n"
    if SLMON::Auth::verify_password('regress-secret', $after->{admin_pass_hash});
die "new password does not match\n"
    if !SLMON::Auth::verify_password('new-secret', $after->{admin_pass_hash});
my $old_cookie = SLMON::Auth::sign_session('admin', time + 100, $before->{session_secret});
die "old cookie still verifies\n"
    if defined SLMON::Auth::verify_session($old_cookie, $after->{session_secret}, time);
$hash = $after->{admin_pass_hash};
($st, $out) = run_capture($^X, "$root/bin/slctl", 'init', '-c', $conf, '-d', $db);
die "init after passwd status $st\n[$out]\n" if $st != 0;
die "init after passwd text:\n[$out]\n" if $out !~ /slctl: already initialized\n/;
die "init after passwd changed the password\n" if admin_hash($db) ne $hash;

my $probe = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => 0,
	Proto     => 'tcp',
	Listen    => 1,
) or die "probe socket: $!";
my $newport = $probe->sockport;
close $probe;

my @db_before = pids_exact('sld: db');
$starter_pid = fork();
die "fork: $!" if !defined $starter_pid;
if ($starter_pid == 0) {
	open STDIN, '<', '/dev/null' or exit 1;
	open STDOUT, '>', "$work/sld.out" or exit 1;
	open STDERR, '>', "$work/sld.err" or exit 1;
	exec 'ktrace', '-i', '-t', 'c', '-f', "$work/ktrace.out",
	    $^X, "$root/bin/sld", '-c', $conf, '-d', $db;
	exit 1;
}
waitpid $starter_pid, 0;
$st = $?;
$starter_pid = 0;
die "daemon start status $st\n" if $st != 0;

my $deadline = time + 10;
my @new_parent;
while (time < $deadline) {
	my %old = map { $_ => 1 } @parents;
	@new_parent = grep { !$old{$_} } pids_exact('sld: parent');
	last if @new_parent;
	select undef, undef, undef, 0.1;
}
die "pgrep -xf sld: parent did not match\n" if @new_parent != 1;
$parent_pid = $new_parent[0];

my $port = wait_port_file("$work/http.port", undef, 15);
die "health on $port\n" if http_code($port) != 200;
my $stable_dish = 0;
$deadline = time + 10;
while (time < $deadline) {
	$stable_dish = dish_pid($log);
	last if $stable_dish && kill(0, $stable_dish);
	select undef, undef, undef, 0.1;
}
die "fake dish did not stay up\n" if !$stable_dish;

my %olddb = map { $_ => 1 } @db_before;
my @dbpids = grep { !$olddb{$_} } pids_exact('sld: db');
die "db child pid @dbpids\n" if @dbpids != 1;
my $dbpid = $dbpids[0];

my $needle = 'database settings wait for rcctl restart sld';
my %marks;
for my $path ('/var/log/daemon', '/var/log/messages') {
	$marks{$path} = -s $path if -r $path;
}

write_file("$conf.new", <<"END");
db = sqlite
db_path = $other
listen = 127.0.0.1:$newport
dish_host = 127.0.0.1
dish_interval_s = 4
log_level = info
rollup_interval_s = 60
ping_targets = 127.0.0.1
ping_interval_s = 30
disconnect_failures = 3
spike_ms = 200
spike_min_s = 30
END
rename "$conf.new", $conf or die "rename conf: $!";
kill 'HUP', $parent_pid or die "hup: $!";

my $got = wait_port_file("$work/http.port", $newport, 15);
die "listen did not move to $newport (got $got)\n" if $got != $newport;
die "health on new port\n" if http_code($newport) != 200;
$deadline = time + 5;
while (time < $deadline) {
	last if !IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => 1,
	);
	select undef, undef, undef, 0.1;
}
die "old port $port still accepts\n" if IO::Socket::INET->new(
	PeerAddr => '127.0.0.1',
	PeerPort => $port,
	Proto    => 'tcp',
	Timeout  => 1,
);

my $new_dish = wait_dish_pid($log, $stable_dish, 10);
die "dish pid stayed $stable_dish\n" if $new_dish == $stable_dish;
die "db child restarted\n" if !kill(0, $dbpid);
my @db_now = grep { $_ == $dbpid } pids_exact('sld: db');
die "db title gone\n" if @db_now != 1;

die "reload created $other\n" if -e $other || -e "$other-wal" || -e "$other-shm";
my ($ino) = (stat $db)[1];
my $fst = `fstat -p $dbpid 2>&1`;
die "fstat missed the open database\n$fst" if index($fst, $db) < 0 && index($fst, "$ino") < 0;

my $logged = log_grew($needle, \%marks);
if (!$logged && -f "$work/ktrace.out") {
	open my $kd, '-|', 'kdump', '-f', "$work/ktrace.out" or die "kdump: $!";
	while (my $line = <$kd>) {
		if (index($line, $needle) >= 0) {
			$logged = 1;
			last;
		}
	}
	close $kd;
}
die "db_path change was not logged\n" if !$logged;

my $hash3 = admin_hash($db);
die "open database lost the admin password\n" if $hash3 ne $hash;

my @live = ($parent_pid, $dbpid, $new_dish);
push @live, pids_exact('sld: http');
push @live, pids_exact('sld: watchdog');
kill 'TERM', $parent_pid or die "term: $!";
$deadline = time + 8;
while (time < $deadline) {
	my $alive = 0;
	for my $pid (@live) {
		$alive = 1 if $pid && kill 0, $pid;
	}
	$alive = 1 if grep { $_ == $parent_pid } pids_exact('sld: parent');
	last if !$alive;
	select undef, undef, undef, 0.1;
}
my @left;
for my $pid (@live) {
	push @left, $pid if $pid && kill 0, $pid;
}
push @left, pids_exact('sld: parent') if grep { $_ == $parent_pid } pids_exact('sld: parent');
die "TERM left @left\n" if @left;
$parent_pid = 0;

die "test created /var/sl\n" if !$had_var_sl && -d '/var/sl';
print "ok daemon\n";
exit 0;
