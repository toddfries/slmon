package SLMON::StatusMap;

use strict;
use warnings;

use SLMON ();

my %ALERT_BIT = (
	motors_stuck                   => 1,
	thermal_shutdown               => 2,
	thermal_throttle               => 3,
	unexpected_location            => 4,
	mast_not_near_vertical         => 5,
	slow_ethernet_speeds           => 6,
	install_pending                => 8,
	is_heating                     => 9,
	power_supply_thermal_throttle  => 10,
	is_power_save_idle             => 11,
	dbf_telem_stale                => 14,
	low_motor_current              => 16,
	lower_signal_than_predicted    => 17,
	slow_ethernet_speeds_100       => 18,
	obstruction_map_reset          => 19,
	dish_water_detected            => 20,
	router_water_detected          => 21,
	upsu_router_port_slow          => 22,
	no_ethernet_link               => 23,
);

my %LEGACY = (
	0 => 'UNKNOWN',
	1 => 'CONNECTED',
	2 => 'SEARCHING',
	3 => 'BOOTING',
);

sub alerts_bitfield {
	my ($alerts) = @_;
	return 0 if !$alerts;
	my $bits = 0;
	for my $name (keys %ALERT_BIT) {
		$bits |= (1 << $ALERT_BIT{$name}) if SLMON::bool01($alerts->{$name});
	}
	return $bits;
}

sub alert_names {
	my ($bits) = @_;
	$bits = 0 if !defined $bits || $bits !~ /\A[0-9]+\z/;
	my @names;
	for my $name (sort { $ALERT_BIT{$a} <=> $ALERT_BIT{$b} } keys %ALERT_BIT) {
		push @names, $name if $bits & (1 << $ALERT_BIT{$name});
	}
	return @names;
}

sub _num {
	my ($v) = @_;
	return undef if !defined $v;
	return $v + 0;
}

sub status_row {
	my ($doc, $ts) = @_;
	my $st = $doc->{status} || {};
	my $dev = $st->{device_state} || {};
	my $ob  = $st->{obstruction_stats} || {};
	my $gps = $st->{gps_stats} || {};
	my $legacy = $doc->{legacy_state};
	my $state;
	if (defined $legacy) {
		$state = $LEGACY{$legacy} // 'UNKNOWN';
	}
	my $inhibit = SLMON::bool01($gps->{inhibit_gps});
	return {
		ts                            => $ts,
		ping_drop_rate                => _num($st->{pop_ping_drop_rate}),
		ping_latency_ms               => _num($st->{pop_ping_latency_ms}),
		obstr_fraction                => _num($ob->{fraction_obstructed}),
		obstr_valid_s                 => _num($ob->{valid_s}),
		downlink_bps                  => defined $st->{downlink_throughput_bps} ? int($st->{downlink_throughput_bps}) : undef,
		uplink_bps                    => defined $st->{uplink_throughput_bps} ? int($st->{uplink_throughput_bps}) : undef,
		state                         => $state,
		snr                           => _num($st->{signal_quality}),
		uptime_s                      => defined $dev->{uptime_s} ? int($dev->{uptime_s}) : undef,
		seconds_to_first_nonempty_slot => _num($st->{seconds_to_first_nonempty_slot}),
		currently_obstructed          => SLMON::bool01($ob->{currently_obstructed}),
		obstruction_duration          => _num($ob->{avg_prolonged_obstruction_duration_s}),
		obstruction_interval          => _num($ob->{avg_prolonged_obstruction_interval_s}),
		direction_azimuth             => _num($st->{boresight_azimuth_deg}),
		direction_elevation           => _num($st->{boresight_elevation_deg}),
		is_snr_above_noise_floor      => SLMON::bool01($st->{is_snr_above_noise_floor}),
		gps_ready                     => SLMON::bool01($gps->{gps_valid}),
		gps_enabled                   => $inhibit ? 0 : 1,
		gps_sats                      => defined $gps->{gps_sats} ? int($gps->{gps_sats}) : 0,
		alerts_bitfield               => alerts_bitfield($st->{alerts}),
	};
}

sub dish_info {
	my ($doc, $ts) = @_;
	my $st = $doc->{status} || {};
	my $info = $st->{device_info} || {};
	return {
		device_id         => $info->{id},
		hardware_version  => $info->{hardware_version},
		software_version  => $info->{software_version},
		country_code      => $info->{country_code},
		bootcount         => defined $info->{bootcount} ? int($info->{bootcount}) : undef,
		alerts_bitfield   => alerts_bitfield($st->{alerts}),
		last_seen_ts      => $ts,
	};
}

sub outage_event {
	my ($doc, $ts) = @_;
	my $out = $doc->{status}{outage} || {};
	my $cause = $out->{cause} // 0;
	return undef if !$cause;
	my $dur;
	$dur = $out->{duration_ns} / 1e9 if defined $out->{duration_ns};
	return {
		ts         => $ts,
		type       => 'dish_outage',
		duration_s => $dur,
		details    => "cause=$cause start_ns=" . ($out->{start_timestamp_ns} // 0),
	};
}

1;
