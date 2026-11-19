package SLMON::DishProc;

use strict;
use warnings;

use Fcntl qw(F_SETFD);
use IO::Socket::INET;
# A timed connect loads this from inside IO::Socket, after unveil.
# Importing it would hide the builtin select().
use IO::Select ();
use SLMON ();
use SLMON::Config;
use SLMON::DishWire;
use SLMON::History;
use SLMON::Imsg;
use SLMON::StatusMap;

# gRPC reports an unreachable dish as a deadline or a failed connect, and
# croak appends a source location. The operator message is the same fact
# slctl once prints.
sub rpc_warn {
	my ($target, $err) = @_;
	$err //= '';
	$err =~ s/\s+at \S+ line \d+\.?//g;
	$err =~ s/\s+\z//;
	if ($err =~ /Deadline Exceeded|failed to connect|Connection refused|Connection timed out/i) {
		return "sld: dish: $target does not answer\n";
	}
	return "sld: dish: $target: $err\n";
}

sub _reachable {
	my ($host, $port) = @_;
	my $sock = IO::Socket::INET->new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => 2,
	);
	return 0 if !$sock;
	close $sock;
	return 1;
}

my %SHAPE_SEEN;

sub client_name {
	my ($cfg) = @_;
	my $name = $cfg->{dish_client} // 'perl';
	return 'perl' if $name eq '';
	return $name;
}

# Dish.so is built only with `make WITH_DISH_XS=yes`. The Perl client is
# the one the default build loads.
sub _load_xs {
	return 1 if $INC{'SLMON/Dish.pm'};
	my $ok = eval { require SLMON::Dish; 1 };
	return 1 if $ok;
	die "dish client xs is not built (make WITH_DISH_XS=yes)\n";
}

sub _note_shape {
	my ($op, $reply) = @_;
	return if ref $reply ne 'HASH';
	for my $row (@{ $reply->{unknown} || [] }) {
		next if ref $row ne 'HASH';
		my $msg = $row->{message} // '';
		my $num = $row->{number} // '';
		my $key = "$op unknown $msg $num";
		next if $SHAPE_SEEN{$key}++;
		warn "sld: dish: $op unknown $msg field $num\n";
	}
	for my $row (@{ $reply->{retyped} || [] }) {
		next if ref $row ne 'HASH';
		my $name = $row->{name} // '';
		my $key = "$op retyped $name";
		next if $SHAPE_SEEN{$key}++;
		warn "sld: dish: $op retyped $name\n";
	}
	return;
}

# The hash StatusMap and History already consume.
sub _doc {
	my ($cfg, $target, $op) = @_;
	if (client_name($cfg) eq 'xs') {
		_load_xs();
		my $raw = SLMON::Dish::call($target, $op);
		my $doc = SLMON::json_decode($raw);
		die "dish $op reply was empty\n" if ref $doc ne 'HASH';
		return $doc;
	}
	my $reply = SLMON::DishWire::call($target, $op);
	my $got = ref $reply eq 'HASH' ? ($reply->{op} // '') : '';
	die "dish $op reply was $got\n" if $got ne $op;
	_note_shape($op, $reply);
	return $reply->{doc} || {};
}

sub call_doc {
	my ($cfg, $target, $op) = @_;
	return _doc($cfg, $target, $op);
}

sub pack_map {
	my ($doc, $ts) = @_;
	my $rows = int($doc->{num_rows} // 0);
	my $cols = int($doc->{num_cols} // 0);
	my $snr = $doc->{snr} || [];
	my $n = scalar @$snr;
	my $bytes = pack('Q< V V V', $ts, $rows, $cols, $n) . pack('f<*', map { $_ // 0 } @$snr);
	die "obstruction map exceeds imsg max\n" if length($bytes) > SLMON::IMSG_MAX;
	return $bytes;
}

sub _chunks {
	my ($samples) = @_;
	my @out;
	my @left = @$samples;
	while (@left) {
		my @part = splice @left, 0, 30;
		push @out, \@part;
	}
	return @out;
}

sub _exec_fake {
	my ($sock) = @_;
	my $cmd = $ENV{SLMON_DISH_CMD} or die "SLMON_DISH_CMD missing\n";
	fcntl($sock, F_SETFD, 0) or die "fcntl: $!\n";
	$ENV{SLMON_DB_FD} = fileno($sock);
	exec $^X, $cmd or die "exec $cmd: $!\n";
}

sub _wait {
	my ($imsg, $deadline) = @_;
	while (1) {
		while (my $m = $imsg->get) {
			return $m if $m->{type} == SLMON::IMSG_SHUTDOWN;
		}
		my $left = $deadline - time;
		return undef if $left <= 0;
		my $rin = '';
		vec($rin, $imsg->fd, 1) = 1;
		my $n = select($rin, undef, undef, $left);
		next if !$n;
		my $r = $imsg->read_more;
		exit 0 if defined $r && $r == 0;
	}
}

sub _try_pledge {
	my ($xs) = @_;
	require OpenBSD::Pledge;
	require OpenBSD::Unveil;
	# The resolver files stay visible so a dish hostname can be looked
	# up. prot_exec is only for the XS client: Dish.so and abseil load
	# code, and abseil probes a Linux sysfs path that is absent here.
	# rpath lets that open return ENOENT. The Perl client does neither.
	my @read = (
		'/dev/urandom',
		'/etc/resolv.conf',
		'/etc/hosts',
		'/etc/services',
		'/etc/protocols',
		'/etc/nsswitch.conf',
		'/etc/netsvc.conf',
		'/etc/svc.conf',
	);
	for my $path (@read) {
		if (!OpenBSD::Unveil::unveil($path, 'r')) {
			warn "sld: dish unveil $path: $! (left unpledged)\n";
			return;
		}
	}
	if (!OpenBSD::Unveil::unveil()) {
		warn "sld: dish unveil lock: $! (left unpledged)\n";
		return;
	}
	my @prom = qw(inet dns rpath);
	push @prom, 'prot_exec' if $xs;
	if (!OpenBSD::Pledge::pledge(@prom)) {
		warn "sld: dish pledge failed: $! (left unpledged)\n";
	}
	return;
}

sub run {
	my ($sock, $cfg) = @_;
	SLMON::proc_title('dish');
	$SIG{TERM} = sub { exit 0 };
	$SIG{PIPE} = 'IGNORE';
	if ($ENV{SLMON_DISH_CMD}) {
		_exec_fake($sock);
	}
	my $imsg = SLMON::Imsg->open(fileno($sock));
	my $xs = client_name($cfg) eq 'xs';
	if ($xs && !eval { _load_xs(); 1 }) {
		warn "sld: dish client xs is not built (make WITH_DISH_XS=yes)\n";
		while (1) {
			my $wake = _wait($imsg, time + 3600);
			last if $wake && $wake->{type} == SLMON::IMSG_SHUTDOWN;
		}
		exit 0;
	}
	_try_pledge($xs);
	my ($host, $port) = SLMON::Config::dish_endpoint($cfg);
	my $target = "$host:$port";
	my $interval = $cfg->{dish_interval_s} || 30;
	$interval = SLMON::MIN_POLL_S if $interval < SLMON::MIN_POLL_S;
	my $next = 0;
	my $next_map = 0;
	my $boot;
	my $last_outage = '';
	my $reported = '';
	while (1) {
		my $wake = _wait($imsg, $next);
		last if $wake && $wake->{type} == SLMON::IMSG_SHUTDOWN;
		my $now = time;
		if (!_reachable($host, $port)) {
			my $msg = "sld: dish: $target does not answer\n";
			warn $msg if $msg ne $reported;
			$reported = $msg;
			$next = time + $interval;
			next;
		}
		eval {
			my $doc = _doc($cfg, $target, 'status');
			my $row = SLMON::StatusMap::status_row($doc, $now);
			my $info = SLMON::StatusMap::dish_info($doc, $now);
			$boot = $info->{bootcount};
			$imsg->send(SLMON::IMSG_STATUS, SLMON::json_encode($row));
			$imsg->send(SLMON::IMSG_DISH_INFO, SLMON::json_encode($info));
			my $ev = SLMON::StatusMap::outage_event($doc, $now);
			if ($ev && ($ev->{details} // '') ne $last_outage) {
				$last_outage = $ev->{details} // '';
				$imsg->send(SLMON::IMSG_EVENT, SLMON::json_encode($ev));
			}
			my $hdoc = _doc($cfg, $target, 'history');
			my @samples = SLMON::History::ring_samples($hdoc, $now);
			my $current = @samples ? $samples[-1]{counter} : undef;
			for my $part (_chunks(\@samples)) {
				$imsg->send(SLMON::IMSG_HISTORY, SLMON::json_encode({
					bootcount => $boot,
					current   => $current,
					samples   => $part,
				}));
			}
			if ($now >= $next_map) {
				my $mdoc = _doc($cfg, $target, 'map');
				$imsg->send(SLMON::IMSG_OBSTRUCTION, pack_map($mdoc, $now));
				$next_map = $now + SLMON::MAP_POLL_S;
			}
		};
		if ($@) {
			my $msg = rpc_warn($target, $@);
			warn $msg if $msg ne $reported;
			$reported = $msg;
		} elsif ($reported ne '') {
			warn "sld: dish: $target answered\n";
			$reported = '';
		}
		$next = time + $interval;
	}
	exit 0;
}

1;
