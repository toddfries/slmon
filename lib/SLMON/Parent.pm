package SLMON::Parent;

use strict;
use warnings;

use IO::Socket::INET;
use POSIX qw(:sys_wait_h);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use SLMON ();
use SLMON::Auth;
use SLMON::Config;
use SLMON::DB;
use SLMON::DishProc;
use SLMON::Http;
use SLMON::Imsg;
use SLMON::Watchdog;
use SLMON::Weather;

our $ACTIVE = 0;
our $IS_CHILD = 0;
our $DBPID;
our %KIDS;
our $CTL_FD;

END {
	return if !$ACTIVE || $IS_CHILD;
	kill 'TERM', $DBPID if $DBPID;
	for my $kid (values %KIDS) {
		kill 'TERM', $kid->{pid} if $kid && $kid->{pid};
	}
}

sub _spair {
	socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
	    or die "socketpair: $!\n";
	return ($a, $b);
}

sub _mkdir_state {
	my ($dir) = @_;
	return if -d $dir;
	mkdir $dir, 0700 or die "mkdir $dir: $!\n";
	chmod 0700, $dir;
	return;
}

sub _handshake {
	my ($ctl) = @_;
	my $first = $ctl->recv;
	die "slmon: db closed during startup\n" if !$first;
	if ($first->{type} == SLMON::IMSG_READY) {
		return 'ready';
	}
	if ($first->{type} != SLMON::IMSG_NEED_INIT) {
		die "slmon: unexpected startup message $first->{type}\n";
	}
	my ($user, $pw) = SLMON::Auth::prompt();
	my $hash = SLMON::Auth::hash_password($pw);
	my $secret = SLMON::Auth::session_secret();
	$ctl->send(SLMON::IMSG_SET_AUTH, SLMON::json_encode({
		user            => $user,
		pass_hash       => $hash,
		session_secret  => $secret,
	}));
	my $ready = $ctl->recv;
	die "slmon: db did not become ready\n"
	    if !$ready || $ready->{type} != SLMON::IMSG_READY;
	return 'created';
}

sub _bind {
	my ($cfg) = @_;
	my ($host, $port) = SLMON::Config::listen_endpoint($cfg);
	my $sock = IO::Socket::INET->new(
		LocalAddr => $host,
		LocalPort => $port,
		Proto     => 'tcp',
		Listen    => 128,
		ReuseAddr => 1,
	) or die "slmon: listen $host:$port: $!\n";
	return $sock;
}

sub _write_port {
	my ($cfg, $sock) = @_;
	my $port = $sock->sockport;
	my $path = "$cfg->{state_dir}/http.port";
	my $tmp = "$path.tmp";
	open my $fh, '>', $tmp or die "slmon: $tmp: $!\n";
	print $fh "$port\n" or die "slmon: $tmp: $!\n";
	close $fh or die "slmon: $tmp: $!\n";
	rename $tmp, $path or die "rename $path: $!\n";
	return $port;
}

sub _spawn {
	my ($name, $ctl, $cfg, $listen) = @_;
	my ($db_end, $wk_end) = _spair();
	$ctl->send_fd(SLMON::IMSG_ATTACH,
	    SLMON::json_encode({ peer => $name }), fileno($db_end));
	close $db_end;
	my $ack = $ctl->recv;
	die "slmon: db did not ack $name\n"
	    if !$ack || $ack->{type} != SLMON::IMSG_ACK;
	my $pid = fork();
	die "fork: $!\n" if !defined $pid;
	if ($pid == 0) {
		$IS_CHILD = 1;
		$ACTIVE = 0;
		close $listen if $name ne 'http';
		eval {
			if ($name eq 'dish') {
				SLMON::DishProc::run($wk_end, $cfg);
			} elsif ($name eq 'http') {
				SLMON::Http::run($wk_end, $listen, $cfg);
			} elsif ($name eq 'watchdog') {
				SLMON::Watchdog::run($wk_end, $cfg);
			} elsif ($name eq 'weather') {
				SLMON::Weather::run($wk_end, $cfg);
			} else {
				die "unknown worker $name\n";
			}
		};
		warn "slmon: $name: $@" if $@;
		POSIX::_exit($@ ? 1 : 0);
	}
	close $wk_end;
	$KIDS{$name} = { pid => $pid, started => time };
	return;
}

sub _kill_workers {
	for my $kid (values %KIDS) {
		kill 'TERM', $kid->{pid} if $kid && $kid->{pid};
	}
	return;
}

sub _pledge_parent {
	require OpenBSD::Pledge;
	OpenBSD::Pledge::pledge(qw(
	    proc exec rpath wpath cpath inet dns flock
	    sendfd recvfd unix prot_exec
	)) or die "slmon: parent pledge: $!\n";
	return;
}

sub _drain {
	my ($dbpid) = @_;
	my $deadline = time + 5;
	while (time < $deadline) {
		my $pid = waitpid(-1, WNOHANG);
		last if !defined $pid || $pid < 0;
		select undef, undef, undef, 0.05 if $pid == 0;
	}
	kill 'KILL', $dbpid if $dbpid && kill 0, $dbpid;
	for my $kid (values %KIDS) {
		kill 'KILL', $kid->{pid} if $kid && $kid->{pid} && kill 0, $kid->{pid};
	}
	while (waitpid(-1, WNOHANG) > 0) {}
	return;
}

sub _supervise {
	my ($ctl, $dbpid, $cfg, $listen, $quit) = @_;
	while (!$$quit) {
		my $pid = waitpid(-1, WNOHANG);
		if (!defined $pid || $pid <= 0) {
			select undef, undef, undef, 0.2;
			next;
		}
		if ($pid == $dbpid) {
			warn "slmon: db child exited\n";
			_kill_workers();
			_drain($dbpid);
			exit 1;
		}
		my $name;
		for my $n (keys %KIDS) {
			if ($KIDS{$n}{pid} == $pid) {
				$name = $n;
				last;
			}
		}
		next if !$name;
		my $started = $KIDS{$name}{started};
		delete $KIDS{$name};
		next if $$quit;
		if (time - $started < 2) {
			sleep 1;
		}
		next if $$quit;
		_spawn($name, $ctl, $cfg, $listen);
	}
	eval { $ctl->send(SLMON::IMSG_SHUTDOWN, '{}') };
	_kill_workers();
	kill 'TERM', $dbpid if $dbpid;
	_drain($dbpid);
	%KIDS = ();
	$DBPID = undef;
	$ACTIVE = 0;
	return;
}

sub run {
	my ($cfg, %opt) = @_;
	SLMON::proc_title('parent');
	$ACTIVE = 1;
	$SIG{PIPE} = 'IGNORE';
	my $quit = 0;
	$SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { $quit = 1 };
	_mkdir_state($cfg->{state_dir});
	my ($pctl, $dctl) = _spair();
	my $dbpid = fork();
	die "fork: $!\n" if !defined $dbpid;
	if ($dbpid == 0) {
		$IS_CHILD = 1;
		$ACTIVE = 0;
		close $pctl;
		eval { SLMON::DB::child($dctl, $cfg) };
		warn "slmon: db: $@" if $@;
		POSIX::_exit($@ ? 1 : 0);
	}
	$DBPID = $dbpid;
	close $dctl;
	my $ctl = SLMON::Imsg->open(fileno($pctl));
	$CTL_FD = fileno($pctl);
	my $how = eval { _handshake($ctl) };
	if ($@) {
		my $err = $@;
		kill 'TERM', $dbpid;
		waitpid $dbpid, 0;
		$ACTIVE = 0;
		$DBPID = undef;
		die $err;
	}
	if ($opt{init_only}) {
		if ($how eq 'ready') {
			print "slmon: already initialized\n";
		} else {
			print "slmon: admin password saved\n";
		}
		$ctl->send(SLMON::IMSG_SHUTDOWN, '{}');
		waitpid $dbpid, 0;
		$ACTIVE = 0;
		$DBPID = undef;
		return $how;
	}
	my $listen = _bind($cfg);
	my $port = _write_port($cfg, $listen);
	print "slmon: listening on $port\n";
	my @workers = qw(dish http watchdog);
	if (($cfg->{latitude} // '') ne '' && ($cfg->{longitude} // '') ne '') {
		push @workers, 'weather';
	}
	for my $name (@workers) {
		_spawn($name, $ctl, $cfg, $listen);
	}
	_pledge_parent();
	_supervise($ctl, $dbpid, $cfg, $listen, \$quit);
	return;
}

sub status {
	my ($cfg) = @_;
	my $port = '';
	my $port_path = "$cfg->{state_dir}/http.port";
	if (open my $fh, '<', $port_path) {
		$port = <$fh> // '';
		chomp $port;
		close $fh;
	}
	my $dbh = eval { SLMON::DB::open_db($cfg, readonly => 1) };
	if (!$dbh) {
		print "database: closed\n";
		print "http_port: $port\n";
		return 1;
	}
	my $settings = eval { SLMON::DB::settings($dbh) };
	print 'initialized: ', ($settings ? 'yes' : 'no'), "\n";
	print "db: $cfg->{db}\n";
	print "dish_host: $cfg->{dish_host}\n";
	print "http_port: $port\n";
	my ($hist) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
	my ($latest) = $dbh->selectrow_array('SELECT MAX(ts) FROM metrics');
	print 'history_samples: ', ($hist // 0), "\n";
	print 'latest_metric_ts: ', (defined $latest ? $latest : ''), "\n";
	return 0;
}

sub once {
	my ($cfg) = @_;
	my ($host, $port) = SLMON::Config::dish_endpoint($cfg);
	my $sock = IO::Socket::INET->new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => 2,
	);
	if (!$sock) {
		print STDERR "slmon: $host:$port does not answer\n";
		return 0;
	}
	close $sock;
	require SLMON::Dish;
	my $json = SLMON::Dish::call("$host:$port", 'status');
	print $json, "\n";
	return 0;
}

1;
