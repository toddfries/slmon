#!/usr/bin/perl

use strict;
use warnings;
use File::Path qw(remove_tree);
use FindBin;
use IO::Socket::INET;
use JSON::PP ();

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../blib";
use SLMON ();
use SLMON::Config;
use SLMON::DB;

require "$FindBin::Bin/pgutil.pl";

my $which = shift @ARGV or die "usage: e2e.pl sqlite|pg\n";
die "usage: e2e.pl sqlite|pg\n" if $which ne 'sqlite' && $which ne 'pg';

my $root = "$FindBin::Bin/..";
chdir $root or die "chdir $root: $!";
my $work = "/tmp/slmon-e2e-$which-$$";
mkdir $work, 0700 or die "mkdir $work: $!";
my $stop;
my $pty_pid;
my $daemon_pid;

sub dump_logs {
	for my $name ('pty.err', 'first.err', 'first.out', 'second.err', 'second.out', 'pg.log') {
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
	if ($daemon_pid && kill 0, $daemon_pid) {
		kill 'TERM', $daemon_pid;
		waitpid $daemon_pid, 0;
	}
	if ($stop) {
		my $fn = $stop;
		$stop = undef;
		$fn->();
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

sub slmon_alive {
	my ($needle) = @_;
	open my $ps, '-|', 'ps', '-axo', 'pid,command' or die "ps: $!";
	while (my $line = <$ps>) {
		next if index($line, $needle) < 0;
		return 1 if $line =~ /sld:|fakedish/;
	}
	close $ps;
	return 0;
}

sub http_req {
	my ($port, $method, $path, $body, $cookie) = @_;
	my $sock = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => 5,
	) or die "http connect: $!";
	my $msg = "$method $path HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n";
	$msg .= "Cookie: slmon_session=$cookie\r\n" if defined $cookie && $cookie ne '';
	if (defined $body) {
		$msg .= "Content-Type: application/json\r\n";
		$msg .= 'Content-Length: ' . length($body) . "\r\n\r\n";
		$msg .= $body;
	} else {
		$msg .= "\r\n";
	}
	syswrite $sock, $msg or die "http write: $!";
	local $/;
	my $resp = <$sock>;
	die "empty http response\n" if !defined $resp || $resp eq '';
	my ($code) = $resp =~ /\AHTTP\/\S+\s+(\d+)/;
	die "no status in [$resp]\n" if !defined $code;
	my ($set) = $resp =~ /Set-Cookie:\s*slmon_session=([^;\s]+)/;
	my ($resp_body) = $resp =~ /\r\n\r\n(.*)\z/s;
	return ($code + 0, $resp_body // '', $set);
}

sub wait_port {
	my ($path, $seconds) = @_;
	my $deadline = time + $seconds;
	while (time < $deadline) {
		if (open my $fh, '<', $path) {
			my $line = <$fh>;
			close $fh;
			if (defined $line && $line =~ /(\d+)/) {
				my $port = $1;
				my $sock = IO::Socket::INET->new(
					PeerAddr => '127.0.0.1',
					PeerPort => $port,
					Proto    => 'tcp',
					Timeout  => 1,
				);
				return $port if $sock;
			}
		}
		select undef, undef, undef, 0.2;
	}
	die "timed out waiting for $path\n";
}

sub wait_log_lines {
	my ($path, $want, $seconds) = @_;
	my $deadline = time + $seconds;
	while (time < $deadline) {
		my $n = 0;
		if (open my $fh, '<', $path) {
			$n++ while <$fh>;
			close $fh;
		}
		return if $n >= $want;
		select undef, undef, undef, 0.2;
	}
	die "fake dish log did not reach $want starts\n";
}

my $db = "$work/slmon.db";
my $log = "$work/fake.log";
write_file($log, '');
my $base_conf = <<'END';
listen = 127.0.0.1:0
dish_host = 127.0.0.1
dish_interval_s = 30
rollup_interval_s = 1
raw_retention_days = 90
minutely_retention_days = 730
hourly_rollup_days = 365
ping_interval_s = 1
disconnect_failures = 3
spike_ms = 200
spike_min_s = 30
END
if ($which eq 'pg') {
	$stop = pg_up($work);
	$base_conf .= "db = pg\npg_db = slmon\npg_user = slmon\npg_host = $work/pg\n";
} else {
	$base_conf .= "db = sqlite\n";
}
write_file("$work/ok.conf", $base_conf . "ping_targets = 127.0.0.1\n");
write_file("$work/down.conf", $base_conf . "ping_targets = 192.0.2.1\n");
write_file("$work/prompt.script", <<'END');
W Admin user
S
W Password:
S regress-secret
W Repeat password:
S regress-secret
END

$ENV{SLMON_DISH_CMD} = "$root/regress/fakedish.pl";
$ENV{SLMON_FAKE_LOG} = $log;
$ENV{PERL5LIB} = "$root/lib:$root/blib";

pipe(my $out_r, my $out_w) or die "pipe: $!";
pipe(my $in_r, my $in_w) or die "pipe: $!";
$pty_pid = fork();
die "fork: $!" if !defined $pty_pid;
if ($pty_pid == 0) {
	close $out_r;
	close $in_w;
	open STDIN, '<&', $in_r or die "stdin: $!";
	open STDOUT, '>&', $out_w or die "stdout: $!";
	open STDERR, '>', "$work/pty.err" or die "stderr: $!";
	exec "$root/regress/ptyfeed", "$work/prompt.script",
	    $^X, "$root/bin/slctl", 'init', '-c', "$work/ok.conf", '-d', $db;
	die "exec ptyfeed: $!";
}
close $out_w;
close $in_r;
my $pid_line = <$out_r>;
die "ptyfeed did not report a pid\n" if !defined $pid_line || $pid_line !~ /PID\s+(\d+)/;
$daemon_pid = $1;

print $in_w "QUIT\n";
close $in_w;
waitpid $pty_pid, 0;
my $st = $?;
$pty_pid = 0;
$daemon_pid = 0;
die "init exit status $st\n" if $st != 0;

my $first = fork();
die "fork: $!" if !defined $first;
if ($first == 0) {
	open STDIN, '<', '/dev/null' or exit 1;
	open STDOUT, '>', "$work/first.out" or exit 1;
	open STDERR, '>', "$work/first.err" or exit 1;
	exec $^X, "$root/bin/sld", '-F', '-c', "$work/ok.conf", '-d', $db;
	exit 1;
}
$daemon_pid = $first;

my $port = wait_port("$work/http.port", 20);
my ($code, $body, $cookie) = http_req($port, 'POST', '/api/login',
    '{"user":"admin","password":"not-the-password"}');
die "wrong password status $code\n" if $code != 401;

($code, $body, $cookie) = http_req($port, 'POST', '/api/login',
    '{"user":"admin","password":"regress-secret"}');
die "login status $code body $body\n" if $code != 200 || !defined $cookie;

($code, $body) = http_req($port, 'GET', '/health');
die "/health status $code\n" if $code != 200;

($code, $body) = http_req($port, 'GET', '/api/latest/history_samples');
die "missing cookie status $code\n" if $code != 401;

wait_log_lines($log, 2, 15);
my $hist = undef;
my $deadline = time + 20;
while (time < $deadline) {
	($code, $body) = http_req($port, 'GET', '/api/latest/history_samples', undef, $cookie);
	if ($code == 200) {
		my $doc = SLMON::json_decode($body);
		if ($doc && @{ $doc->{rows} || [] }) {
			$hist = $doc->{rows}[0];
			last;
		}
	}
	select undef, undef, undef, 0.3;
}
die "latest history did not appear ($code $body)\n" if !$hist;
die "scripted counter missing\n" if ($hist->{dish_counter} // 0) < 1000;

my $from = $hist->{ts} - 120;
my $to = $hist->{ts} + 5;
($code, $body) = http_req($port, 'GET',
    "/api/raw/history_samples?from=$from&to=$to&limit=100", undef, $cookie);
die "raw status $code\n" if $code != 200;
my $raw = SLMON::json_decode($body);
my $nrows = scalar @{ $raw->{rows} || [] };
die "raw row count $nrows\n" if $nrows != 60;

my $minute;
$deadline = time + 15;
while (time < $deadline) {
	($code, $body) = http_req($port, 'GET', '/api/latest/metrics_minutely', undef, $cookie);
	if ($code == 200) {
		my $doc = SLMON::json_decode($body);
		if ($doc && @{ $doc->{rows} || [] }) {
			$minute = $doc->{rows}[0];
			last if ($minute->{down_bytes} // 0) == 60000;
		}
	}
	select undef, undef, undef, 0.3;
}
die "minutely down_bytes not 60000\n" if !$minute || $minute->{down_bytes} != 60000;

my $saw_ok = 0;
$deadline = time + 20;
while (time < $deadline) {
	($code, $body) = http_req($port, 'GET', '/api/raw/events?limit=50', undef, $cookie);
	if ($code == 200) {
		my $doc = SLMON::json_decode($body);
		$saw_ok = grep { ($_->{type} // '') eq 'ping_ok' } @{ $doc->{rows} || [] };
		last if $saw_ok;
	}
	select undef, undef, undef, 0.4;
}
die "watchdog success did not show up in events\n" if !$saw_ok;

kill 'TERM', $first;
waitpid $first, 0;
$st = $?;
$daemon_pid = 0;
die "first daemon exit status $st\n" if $st != 0;
die "children still running after SIGTERM\n" if slmon_alive($db);

my $cfg = SLMON::Config::load_file("$work/ok.conf");
SLMON::Config::apply_paths($cfg, db_path => $db, root => '/none');
if ($which eq 'pg') {
	$cfg->{pg_host} = "$work/pg";
}
my $dbh = SLMON::DB::open_db($cfg, readonly => 1);
my ($stored) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
die "reopen saw $stored history rows\n" if $stored != 60;
$dbh->disconnect;

my $second = fork();
die "fork: $!" if !defined $second;
if ($second == 0) {
	open STDIN, '<', '/dev/null' or exit 1;
	open STDOUT, '>', "$work/second.out" or exit 1;
	open STDERR, '>', "$work/second.err" or exit 1;
	exec $^X, "$root/bin/sld", '-F', '-c', "$work/down.conf", '-d', $db;
	exit 1;
}
$daemon_pid = $second;
$port = wait_port("$work/http.port", 15);
($code, $body, $cookie) = http_req($port, 'POST', '/api/login',
    '{"user":"admin","password":"regress-secret"}');
die "second start login $code (prompted or refused)\n" if $code != 200;

my $saw_down = 0;
$deadline = time + 40;
while (time < $deadline) {
	($code, $body) = http_req($port, 'GET', '/api/raw/events?limit=50', undef, $cookie);
	if ($code == 200) {
		my $doc = SLMON::json_decode($body);
		$saw_down = grep {
			($_->{type} // '') eq 'disconnect' && !defined $_->{duration_s}
		} @{ $doc->{rows} || [] };
		last if $saw_down;
	}
	select undef, undef, undef, 0.5;
}
die "blackhole disconnect did not show up in events\n" if !$saw_down;

kill 'TERM', $second;
waitpid $second, 0;
$st = $?;
$daemon_pid = 0;
die "second daemon exit status $st\n" if $st != 0;
die "children still running after second SIGTERM\n" if slmon_alive($db);

$dbh = SLMON::DB::open_db($cfg, readonly => 1);
($stored) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
die "database did not reopen ($stored)\n" if $stored != 60;
$dbh->disconnect;

print "ok e2e $which\n";
exit 0;
