package SLMON::History;

use strict;
use warnings;

# 1 Hz samples from a get_history ring. Buffer length is the array length.
# When current < N the valid prefix is 0 .. current-1.
# When the ring has wrapped, the oldest slot is current % N and the oldest
# counter is current - N + 1. Latency is NULL when the drop rate is >= 1.
sub ring_samples {
	my ($doc, $now) = @_;
	my $drop = $doc->{pop_ping_drop_rate} || [];
	my $lat  = $doc->{pop_ping_latency_ms} || [];
	my $down = $doc->{downlink_throughput_bps} || [];
	my $up   = $doc->{uplink_throughput_bps} || [];
	my $n = scalar @$drop;
	return () if $n <= 0;
	my $current = int($doc->{current} // 0);
	my ($nvalid, $oldest, $first);
	if ($current < $n) {
		$nvalid = $current;
		$oldest = 0;
		$first  = 1;
	} else {
		$nvalid = $n;
		$oldest = $current % $n;
		$first  = $current - $n + 1;
	}
	my @out;
	for (my $i = 0; $i < $nvalid; $i++) {
		my $idx = ($oldest + $i) % $n;
		my $counter = $first + $i;
		my $d = $drop->[$idx];
		my $latency = $lat->[$idx];
		$latency = undef if defined $d && $d >= 1;
		push @out, {
			counter  => $counter,
			ts       => $now - ($current - $counter),
			drop     => $d,
			latency  => $latency,
			down_bps => $down->[$idx],
			up_bps   => $up->[$idx],
		};
	}
	return @out;
}

1;
