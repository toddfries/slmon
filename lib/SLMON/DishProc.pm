package SLMON::DishProc;

use strict;
use warnings;

use Fcntl qw(F_SETFD);
use SLMON ();
use SLMON::Config;
use SLMON::History;
use SLMON::Imsg;
use SLMON::StatusMap;

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
	require OpenBSD::Pledge;
	require OpenBSD::Unveil;
	# c-ares opens resolver files itself, so the dns promise's libc
	# whitelist does not cover them. Abseil also probes a Linux sysfs
	# path that is absent here; rpath lets that open return ENOENT
	# instead of killing the process. The unveil list is the rest of
	# what this child may read.
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
			warn "slmon: dish unveil $path: $! (left unpledged)\n";
			return;
		}
	}
	if (!OpenBSD::Unveil::unveil()) {
		warn "slmon: dish unveil lock: $! (left unpledged)\n";
		return;
	}
	if (!OpenBSD::Pledge::pledge(qw(inet dns prot_exec rpath))) {
		warn "slmon: dish pledge failed: $! (left unpledged)\n";
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
	require SLMON::Dish;
	my $imsg = SLMON::Imsg->open(fileno($sock));
	_try_pledge();
	my ($host, $port) = SLMON::Config::dish_endpoint($cfg);
	my $target = "$host:$port";
	my $interval = $cfg->{dish_interval_s} || 30;
	my $next = 0;
	my $next_map = 0;
	my $boot;
	my $last_outage = '';
	while (1) {
		my $wake = _wait($imsg, $next);
		last if $wake && $wake->{type} == SLMON::IMSG_SHUTDOWN;
		my $now = time;
		eval {
			my $raw = SLMON::Dish::call($target, 'status');
			my $doc = SLMON::json_decode($raw);
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
			my $hraw = SLMON::Dish::call($target, 'history');
			my $hdoc = SLMON::json_decode($hraw);
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
				my $mraw = SLMON::Dish::call($target, 'map');
				my $mdoc = SLMON::json_decode($mraw);
				$imsg->send(SLMON::IMSG_OBSTRUCTION, pack_map($mdoc, $now));
				$next_map = $now + 300;
			}
		};
		warn "slmon: dish: $@" if $@;
		$next = time + $interval;
	}
	exit 0;
}

1;
