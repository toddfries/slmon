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
our $RELOAD = 0;
our $LISTEN;

END {
	return if !$ACTIVE || $IS_CHILD;
	kill 'TERM', $DBPID if $DBPID;
	for my $kid (values %KIDS) {
		kill 'TERM', $kid->{pid} if $kid && $kid->{pid};
	}
}

# uid 0 must not initialize or replace the admin login.
sub init_refused {
	my ($uid, $cmd) = @_;
	$cmd = 'init' if !defined $cmd || $cmd eq '';
	return "slctl: doas -u _sl slctl $cmd" if defined $uid && $uid == 0;
	return undef;
}

sub _spair {
	socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
	    or die "socketpair: $!\n";
	return ($a, $b);
}

sub _abs_path {
	my ($path) = @_;
	return $path if !defined $path || $path eq '' || $path =~ m{\A/};
	require Cwd;
	my $cwd = Cwd::getcwd() || '.';
	return "$cwd/$path";
}

# The port creates /var/sl. Other directories (regress -d) may be created.
sub _mkdir_state {
	my ($dir) = @_;
	return if -d $dir;
	if ($dir eq '/var/sl') {
		die SLMON::err('/var/sl: no such directory');
	}
	mkdir $dir, 0700 or die "mkdir $dir: $!\n";
	chmod 0700, $dir;
	return;
}

sub _not_initialized {
	my ($what) = @_;
	SLMON::op_both("$what is not initialized", 'doas -u _sl slctl init');
	exit 1;
}

# Missing file, or a file with no admin password. Does not create a database.
sub _require_initialized {
	my ($cfg) = @_;
	if (($cfg->{db} // '') eq 'sqlite' && !-e $cfg->{db_path}) {
		_not_initialized($cfg->{db_path});
	}
	my $dbh = eval { SLMON::DB::open_db($cfg) };
	if (!$dbh) {
		if (($cfg->{db} // '') eq 'sqlite') {
			_not_initialized($cfg->{db_path});
		}
		die $@;
	}
	my $row = eval { SLMON::DB::settings($dbh) };
	$dbh->disconnect;
	if (!$row || !defined $row->{admin_pass_hash} || $row->{admin_pass_hash} eq '') {
		my $what = ($cfg->{db} // '') eq 'pg'
		    ? ($cfg->{pg_db} || 'pg')
		    : $cfg->{db_path};
		_not_initialized($what);
	}
	return;
}

sub _daemonize {
	pipe my $r, my $w or die "pipe: $!\n";
	my $pid = fork();
	die "fork: $!\n" if !defined $pid;
	if ($pid > 0) {
		close $w;
		my $got = <$r>;
		$ACTIVE = 0;
		POSIX::_exit(($got // '') eq "ok\n" ? 0 : 1);
	}
	close $r;
	POSIX::setsid();
	umask 0077;
	chdir '/' or POSIX::_exit(1);
	$SLMON::LOG_STDERR = 0;
	$SIG{__WARN__} = sub {
		my ($m) = @_;
		SLMON::op($m);
	};
	open STDIN, '<', '/dev/null' or POSIX::_exit(1);
	open STDOUT, '>', '/dev/null' or POSIX::_exit(1);
	open STDERR, '>', '/dev/null' or POSIX::_exit(1);
	print $w "ok\n";
	close $w;
	return;
}

sub _set_auth {
	my ($ctl) = @_;
	my ($user, $pw) = SLMON::Auth::prompt();
	my $hash = SLMON::Auth::hash_password($pw);
	# A new key drops cookies signed with the previous one after restart.
	my $secret = SLMON::Auth::session_secret();
	$ctl->send(SLMON::IMSG_SET_AUTH, SLMON::json_encode({
		user            => $user,
		pass_hash       => $hash,
		session_secret  => $secret,
	}));
	my $ready = $ctl->recv;
	die SLMON::err('db did not become ready')
	    if !$ready || $ready->{type} != SLMON::IMSG_READY;
	return;
}

sub _handshake {
	my ($ctl, $replace) = @_;
	my $first = $ctl->recv;
	die SLMON::err('db closed during startup') if !$first;
	if ($first->{type} == SLMON::IMSG_READY) {
		if (!$replace) {
			return 'ready';
		}
		_set_auth($ctl);
		return 'reset';
	}
	if ($first->{type} != SLMON::IMSG_NEED_INIT) {
		die SLMON::err("unexpected startup message $first->{type}");
	}
	if ($replace) {
		return 'missing';
	}
	_set_auth($ctl);
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
	) or die SLMON::err("listen $host:$port: $!");
	return $sock;
}

sub _write_port {
	my ($cfg, $sock) = @_;
	my $port = $sock->sockport;
	my $path = "$cfg->{state_dir}/http.port";
	my $tmp = "$path.tmp";
	open my $fh, '>', $tmp or die SLMON::err("$tmp: $!");
	print $fh "$port\n" or die SLMON::err("$tmp: $!");
	close $fh or die SLMON::err("$tmp: $!");
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
	die SLMON::err("db did not ack $name")
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
		SLMON::op("$name: $@") if $@;
		POSIX::_exit($@ ? 1 : 0);
	}
	close $wk_end;
	$KIDS{$name} = { pid => $pid, started => time };
	return;
}

sub _stop_worker {
	my ($name) = @_;
	my $kid = delete $KIDS{$name} or return;
	return if !$kid->{pid};
	kill 'TERM', $kid->{pid};
	my $deadline = time + 2;
	while (time < $deadline) {
		my $got = waitpid($kid->{pid}, WNOHANG);
		last if !defined $got || $got < 0 || $got == $kid->{pid};
		select undef, undef, undef, 0.05;
	}
	if (kill 0, $kid->{pid}) {
		kill 'KILL', $kid->{pid};
		waitpid($kid->{pid}, 0);
	}
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
	# unveil stays in the superset so a restarted child can still
	# narrow its own view. The parent itself does not call unveil.
	OpenBSD::Pledge::pledge(qw(
	    proc exec rpath wpath cpath inet dns flock
	    sendfd recvfd unix prot_exec unveil
	)) or die SLMON::err("parent pledge: $!");
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

sub _db_keys {
	return qw(db db_path pg_host pg_port pg_db pg_user pg_password);
}

sub _ping_keys {
	return qw(ping_targets ping_interval_s disconnect_failures spike_ms spike_min_s);
}

sub _reload {
	my ($ctl, $cfg) = @_;
	my $path = $cfg->{_file} || '';
	if ($path eq '') {
		SLMON::op('no config file to reload');
		return;
	}
	my $fresh = eval { SLMON::Config::load_file($path) };
	if ($@) {
		my $err = $@;
		$err =~ s/\s+\z//;
		SLMON::op("config not applied: $err");
		return;
	}
	my %keep = map { $_ => 1 } _db_keys();
	my $db_changed = 0;
	for my $k (_db_keys()) {
		$db_changed = 1 if ($fresh->{$k} // '') ne ($cfg->{$k} // '');
	}
	SLMON::op('database settings wait for rcctl restart sld') if $db_changed;
	my $old_listen = $cfg->{listen};
	my $old_dish = $cfg->{dish_host};
	my $old_int = $cfg->{dish_interval_s};
	my $old_client = $cfg->{dish_client} // 'perl';
	my $old_lat = $cfg->{latitude} // '';
	my $old_lon = $cfg->{longitude} // '';
	my %old_ping = map { $_ => ($cfg->{$_} // '') } _ping_keys();
	for my $k (keys %$fresh) {
		next if $keep{$k};
		$cfg->{$k} = $fresh->{$k};
	}
	if (($cfg->{listen} // '') ne $old_listen) {
		my $bound = eval { _bind($cfg) };
		if ($@) {
			my $err = $@;
			$err =~ s/\s+\z//;
			SLMON::op("listen not changed: $err");
			$cfg->{listen} = $old_listen;
		} else {
			_stop_worker('http');
			close $LISTEN if $LISTEN;
			$LISTEN = $bound;
			_write_port($cfg, $LISTEN);
		}
	}
	_stop_worker('http');
	_spawn('http', $ctl, $cfg, $LISTEN);
	if (($cfg->{dish_host} // '') ne $old_dish
	    || ($cfg->{dish_interval_s} // 0) != $old_int
	    || ($cfg->{dish_client} // 'perl') ne $old_client) {
		_stop_worker('dish');
		_spawn('dish', $ctl, $cfg, $LISTEN);
	}
	my $ping_changed = 0;
	for my $k (_ping_keys()) {
		$ping_changed = 1 if ($cfg->{$k} // '') ne $old_ping{$k};
	}
	if ($ping_changed) {
		_stop_worker('watchdog');
		_spawn('watchdog', $ctl, $cfg, $LISTEN);
	}
	my $had_wx = $old_lat ne '' && $old_lon ne '';
	my $lat = $cfg->{latitude} // '';
	my $lon = $cfg->{longitude} // '';
	my $want_wx = $lat ne '' && $lon ne '';
	if ($had_wx && !$want_wx) {
		_stop_worker('weather');
	} elsif ($want_wx && (!$had_wx || $lat ne $old_lat || $lon ne $old_lon)) {
		_stop_worker('weather');
		_spawn('weather', $ctl, $cfg, $LISTEN);
	}
	$ctl->send(SLMON::IMSG_RELOAD, SLMON::json_encode({
		log_level               => $cfg->{log_level},
		raw_retention_days      => $cfg->{raw_retention_days},
		minutely_retention_days => $cfg->{minutely_retention_days},
		hourly_rollup_days      => $cfg->{hourly_rollup_days},
		rollup_interval_s       => $cfg->{rollup_interval_s},
	}));
	return;
}

sub _supervise {
	my ($ctl, $dbpid, $cfg, $quit) = @_;
	while (!$$quit) {
		if ($RELOAD) {
			$RELOAD = 0;
			eval { _reload($ctl, $cfg) };
			SLMON::op("reload: $@") if $@;
		}
		my $pid = waitpid(-1, WNOHANG);
		if (!defined $pid || $pid <= 0) {
			select undef, undef, undef, 0.2;
			next;
		}
		if ($pid == $dbpid) {
			SLMON::op('db child exited');
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
		_spawn($name, $ctl, $cfg, $LISTEN);
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
	$cfg->{db_path} = _abs_path($cfg->{db_path});
	$cfg->{_file} = _abs_path($cfg->{_file}) if defined $cfg->{_file} && $cfg->{_file} ne '';
	if ($cfg->{db_path} =~ m{\A(.+)/[^/]+\z}) {
		$cfg->{state_dir} = $1;
	}
	umask 0077;
	if ($opt{passwd_only}) {
		_require_initialized($cfg);
	} elsif (!$opt{init_only}) {
		_require_initialized($cfg);
		_daemonize() if !$opt{foreground};
	}
	SLMON::proc_title('parent');
	$ACTIVE = 1;
	$SIG{PIPE} = 'IGNORE';
	my $quit = 0;
	$SIG{TERM} = $SIG{INT} = sub { $quit = 1 };
	$SIG{HUP} = sub { $RELOAD = 1 };
	_mkdir_state($cfg->{state_dir});
	my ($pctl, $dctl) = _spair();
	my $dbpid = fork();
	die "fork: $!\n" if !defined $dbpid;
	if ($dbpid == 0) {
		$IS_CHILD = 1;
		$ACTIVE = 0;
		close $pctl;
		eval {
			SLMON::DB::child($dctl, $cfg,
			    $opt{init_only} || $opt{passwd_only});
		};
		SLMON::op("db: $@") if $@;
		POSIX::_exit($@ ? 1 : 0);
	}
	$DBPID = $dbpid;
	close $dctl;
	my $ctl = SLMON::Imsg->open(fileno($pctl));
	$CTL_FD = fileno($pctl);
	my $how = eval { _handshake($ctl, $opt{passwd_only} ? 1 : 0) };
	if ($@) {
		my $err = $@;
		kill 'TERM', $dbpid;
		waitpid $dbpid, 0;
		$ACTIVE = 0;
		$DBPID = undef;
		die $err;
	}
	if ($opt{init_only} || $opt{passwd_only}) {
		if ($opt{init_only}) {
			if ($how eq 'ready') {
				print SLMON::err('already initialized');
			} else {
				print SLMON::err('admin password saved');
			}
		} elsif ($how eq 'reset') {
			print SLMON::err('admin user reset');
			print SLMON::err('rcctl restart sld');
		} else {
			my $what = ($cfg->{db} // '') eq 'pg'
			    ? ($cfg->{pg_db} || 'pg')
			    : $cfg->{db_path};
			print SLMON::err("$what is not initialized");
			print SLMON::err('doas -u _sl slctl init');
		}
		$ctl->send(SLMON::IMSG_SHUTDOWN, '{}');
		waitpid $dbpid, 0;
		$ACTIVE = 0;
		$DBPID = undef;
		return $how;
	}
	$LISTEN = _bind($cfg);
	my $port = _write_port($cfg, $LISTEN);
	SLMON::op("listening on $port");
	my @workers = qw(dish http watchdog);
	if (($cfg->{latitude} // '') ne '' && ($cfg->{longitude} // '') ne '') {
		push @workers, 'weather';
	}
	for my $name (@workers) {
		_spawn($name, $ctl, $cfg, $LISTEN);
	}
	_pledge_parent();
	_supervise($ctl, $dbpid, $cfg, \$quit);
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
	print "db_path: $cfg->{db_path}\n";
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
		print STDERR SLMON::err("$host:$port does not answer");
		return 0;
	}
	close $sock;
	my $doc = eval {
		SLMON::DishProc::call_doc($cfg, "$host:$port", 'status');
	};
	if ($@) {
		my $err = $@;
		$err =~ s/\s+at \S+ line \d+\.?//g;
		$err =~ s/\s+\z//;
		print STDERR SLMON::err($err);
		return 1;
	}
	print SLMON::json_encode($doc), "\n";
	return 0;
}

1;
