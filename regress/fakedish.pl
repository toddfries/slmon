#!/usr/bin/perl

# Speaks the real imsg protocol. The first start emits one scripted minute
# and exits so the parent restarts it. Later starts stay up.

use strict;
use warnings;
use Fcntl qw(:flock);
use FindBin;

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../blib";
use OpenBSD::Pledge;
use SLMON ();
use SLMON::Imsg;

my $fd = $ENV{SLMON_DB_FD};
die "SLMON_DB_FD is not set\n" if !defined $fd || $fd eq '';
my $log = $ENV{SLMON_FAKE_LOG} or die "SLMON_FAKE_LOG is not set\n";

my $starts = 0;
open my $lf, '+>>', $log or die "open $log: $!";
flock $lf, LOCK_EX or die "flock: $!";
seek $lf, 0, 0;
$starts++ while <$lf>;
seek $lf, 0, 2;
print $lf "start $$\n";
close $lf;

pledge(qw(rpath wpath)) or die "pledge: $!";

my $imsg = SLMON::Imsg->open($fd);
my $now = time;
my $minute = $now - 60;
$minute -= $minute % 60;
my @samples;
for my $i (0 .. 59) {
	my $drop = $i == 7 ? 1 : 0;
	push @samples, {
		counter  => 1000 + $i,
		ts       => $minute + $i,
		drop     => $drop,
		latency  => 40,
		down_bps => 8000,
		up_bps   => 1000,
	};
}
my $ts = $now;
$imsg->send(SLMON::IMSG_STATUS, SLMON::json_encode({
	ts => $ts,
	ping_drop_rate => 0,
	ping_latency_ms => 40,
	obstr_fraction => 0,
	downlink_bps => 8000,
	uplink_bps => 1000,
	state => 'CONNECTED',
	alerts_bitfield => 0,
	uptime_s => 10,
	currently_obstructed => 0,
	gps_ready => 1,
	gps_enabled => 1,
	gps_sats => 8,
}));
$imsg->send(SLMON::IMSG_DISH_INFO, SLMON::json_encode({
	device_id => 'fake-dish',
	hardware_version => 'hw',
	software_version => 'sw',
	country_code => 'US',
	bootcount => 4,
	alerts_bitfield => 0,
	last_seen_ts => $ts,
}));
while (@samples) {
	my @part = splice @samples, 0, 30;
	$imsg->send(SLMON::IMSG_HISTORY, SLMON::json_encode({
		bootcount => 4,
		current   => 1059,
		samples   => \@part,
	}));
}

# First invocation exits so the parent has to restart the dish child.
exit 0 if $starts == 0;
while (1) {
	sleep 3600;
}
