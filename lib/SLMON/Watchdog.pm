package SLMON::Watchdog;

use strict;
use warnings;

use SLMON ();

sub state {
	return {
		fail_streak  => 0,
		down         => 0,
		down_since   => undef,
		spike_since  => undef,
		spike_fired  => 0,
	};
}

# $probe is { ok => 0|1, rtt_ms => number|undef }.
# Disconnect confirms on the Nth consecutive failure (duration left unset).
# The next success records the outage duration. A latency spike is logged
# only after the best RTT has stayed above the threshold for spike_min_s.
sub step {
	my ($st, $probe, $now, $cfg) = @_;
	my $need = $cfg->{disconnect_failures} // 3;
	my $spike_ms = $cfg->{spike_ms} // 200;
	my $spike_min = $cfg->{spike_min_s} // 30;
	my @ev;
	if (!$probe->{ok}) {
		$st->{fail_streak}++;
		$st->{spike_since} = undef;
		$st->{spike_fired} = 0;
		if ($st->{fail_streak} >= $need && !$st->{down}) {
			$st->{down} = 1;
			$st->{down_since} = $now;
			push @ev, {
				ts         => $now,
				type       => 'disconnect',
				duration_s => undef,
				details    => 'down',
			};
		}
		return @ev;
	}
	$st->{fail_streak} = 0;
	if ($st->{down}) {
		my $dur = $now - ($st->{down_since} // $now);
		$st->{down} = 0;
		$st->{down_since} = undef;
		push @ev, {
			ts         => $now,
			type       => 'disconnect',
			duration_s => $dur,
			details    => 'up',
		};
	}
	my $rtt = $probe->{rtt_ms};
	if (defined $rtt && $rtt > $spike_ms) {
		$st->{spike_since} //= $now;
		if (!$st->{spike_fired} && ($now - $st->{spike_since}) >= $spike_min) {
			$st->{spike_fired} = 1;
			push @ev, {
				ts         => $now,
				type       => 'latency_spike',
				duration_s => $now - $st->{spike_since},
				details    => "rtt_ms=$rtt",
			};
		}
	} else {
		$st->{spike_since} = undef;
		$st->{spike_fired} = 0;
	}
	return @ev;
}

sub probe_host {
	my ($host) = @_;
	my $pid = open my $fh, '-|', '/sbin/ping', '-n', '-c', '1', '-w', '2', $host;
	if (!defined $pid) {
		return (0, undef);
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	my $ok = $? == 0 ? 1 : 0;
	my $rtt;
	if ($out =~ /time=([0-9.]+)\s*ms/) {
		$rtt = $1 + 0;
	}
	return ($ok, $rtt);
}

sub probe_targets {
	my (@hosts) = @_;
	my $any = 0;
	my $best;
	for my $host (@hosts) {
		next if !defined $host || $host eq '';
		my ($ok, $rtt) = probe_host($host);
		if ($ok) {
			$any = 1;
			if (defined $rtt && (!defined $best || $rtt < $best)) {
				$best = $rtt;
			}
		}
	}
	return { ok => $any, rtt_ms => $best };
}

sub _wait {
	my ($imsg, $seconds) = @_;
	my $deadline = time + $seconds;
	while (1) {
		while (my $m = $imsg->get) {
			return 0 if $m->{type} == SLMON::IMSG_SHUTDOWN;
		}
		my $left = $deadline - time;
		return 1 if $left <= 0;
		my $rin = '';
		vec($rin, $imsg->fd, 1) = 1;
		my $n = select($rin, undef, undef, $left);
		next if !$n;
		my $r = $imsg->read_more;
		return 0 if defined $r && $r == 0;
	}
}

sub run {
	my ($sock, $cfg) = @_;
	SLMON::proc_title('watchdog');
	require SLMON::Imsg;
	my $imsg = SLMON::Imsg->open(fileno($sock));
	require OpenBSD::Pledge;
	require OpenBSD::Unveil;
	OpenBSD::Unveil::unveil('/sbin/ping', 'x')
	    or die "slmon: watchdog unveil: $!\n";
	OpenBSD::Unveil::unveil()
	    or die "slmon: watchdog unveil lock: $!\n";
	OpenBSD::Pledge::pledge(qw(proc exec inet))
	    or die "slmon: watchdog pledge: $!\n";
	my $st = state();
	my $logged_ok = 0;
	my @targets = split /\s*,\s*/, $cfg->{ping_targets} // '';
	my $interval = $cfg->{ping_interval_s} || 10;
	$interval = 1 if $interval < 1;
	while (1) {
		my $probe = probe_targets(@targets);
		my $now = time;
		my @ev = step($st, $probe, $now, $cfg);
		if ($probe->{ok} && !$logged_ok) {
			push @ev, {
				ts         => $now,
				type       => 'ping_ok',
				duration_s => undef,
				details    => defined $probe->{rtt_ms} ? "rtt_ms=$probe->{rtt_ms}" : 'ok',
			};
			$logged_ok = 1;
		}
		if (!$probe->{ok}) {
			$logged_ok = 0;
		}
		for my $ev (@ev) {
			$imsg->send(SLMON::IMSG_EVENT, SLMON::json_encode($ev));
		}
		last if !_wait($imsg, $interval);
	}
	exit 0;
}

1;
