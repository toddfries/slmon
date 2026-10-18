package SLMON::Obstruction;

use strict;
use warnings;

# Fraction >= 0.05 on two consecutive status snapshots fires once,
# on the transition to streak == 2.
sub observe {
	my ($st, $fraction, $ts) = @_;
	$st->{streak} //= 0;
	if (defined $fraction && $fraction >= 0.05) {
		$st->{streak}++;
	} else {
		$st->{streak} = 0;
	}
	if ($st->{streak} == 2) {
		return {
			ts         => $ts,
			type       => 'obstruction',
			duration_s => undef,
			details    => "fraction=$fraction",
		};
	}
	return undef;
}

1;
