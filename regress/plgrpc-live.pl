#!/usr/bin/perl

use strict;
use warnings;
use FindBin;

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../blib";
use JSON::PP ();
use SLMON ();
use SLMON::Config;
use SLMON::Dish;
use SLMON::DishWire;

# One shot. Not part of REGRESS_TARGETS. One connect per op, plus a single
# retry if the first TCP connect fails. Counts and types only.

my $root = "$FindBin::Bin/..";
my $cfg = SLMON::Config::load_file("$root/etc/sl.conf");
my ($host, $port) = SLMON::Config::dish_endpoint($cfg);
my $target = "$host:$port";
my $retried = 0;

my @ALERTS = qw(
    motors_stuck thermal_shutdown thermal_throttle unexpected_location
    mast_not_near_vertical slow_ethernet_speeds install_pending is_heating
    power_supply_thermal_throttle is_power_save_idle dbf_telem_stale
    low_motor_current lower_signal_than_predicted slow_ethernet_speeds_100
    obstruction_map_reset dish_water_detected router_water_detected
    upsu_router_port_slow no_ethernet_link
);

sub kind {
	my ($v) = @_;
	return 'null' if !defined $v;
	return 'bool' if ref($v) eq 'JSON::PP::Boolean';
	return 'object' if ref($v) eq 'HASH';
	return 'array' if ref($v) eq 'ARRAY';
	return 'number' if !ref($v)
	    && $v =~ /\A-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/;
	return 'string' if !ref $v;
	return 'other';
}

sub brief {
	my ($err) = @_;
	$err //= '';
	$err =~ s/\s+at \S+ line \d+\.?//g;
	$err =~ s/\{.*//s;
	$err =~ s/[^\x20-\x7e]/./g;
	$err =~ s/\s+\z//;
	return substr($err, 0, 160);
}

sub perl_call {
	my ($op) = @_;
	my $got = eval { SLMON::DishWire::call($target, $op) };
	return $got if $got;
	my $err = $@;
	if (!$retried && $err =~ /\Aconnect:/) {
		$retried = 1;
		$got = eval { SLMON::DishWire::call($target, $op) };
		return $got if $got;
		$err = $@;
	}
	die $err;
}

sub cpp_call {
	my ($op) = @_;
	my $raw = SLMON::Dish::call($target, $op);
	die "cpp empty reply\n" if !defined $raw || $raw eq '';
	my $doc = SLMON::json_decode($raw);
	die "cpp reply is not an object\n" if ref $doc ne 'HASH';
	return $doc;
}

sub same_keys {
	my ($a, $b, $path, $err) = @_;
	return if ref $a ne 'HASH' || ref $b ne 'HASH';
	my %keys = map { $_ => 1 } (keys %$a, keys %$b);
	for my $k (sort keys %keys) {
		if (!exists $a->{$k} || !exists $b->{$k}) {
			push @$err, "$path.$k missing";
		}
	}
	return;
}

sub cmp_types {
	my ($a, $b, $path, $err) = @_;
	my $ta = kind($a);
	my $tb = kind($b);
	if ($ta ne $tb) {
		push @$err, "$path $ta/$tb";
		return;
	}
	if ($ta eq 'object') {
		same_keys($a, $b, $path, $err);
		for my $k (sort keys %$a) {
			next if !exists $b->{$k};
			cmp_types($a->{$k}, $b->{$k}, "$path.$k", $err);
		}
	} elsif ($ta eq 'array' && @$a != @$b) {
		push @$err, "$path length";
	}
	return;
}

sub count_leaves {
	my ($v, $n) = @_;
	my $t = kind($v);
	if ($t eq 'object') {
		count_leaves($v->{$_}, $n) for keys %$v;
		return;
	}
	if ($t eq 'array') {
		count_leaves($_, $n) for @$v;
		return;
	}
	$n->{$t}++;
	return;
}

sub expect_keys {
	my ($doc, $spec, $path, $err) = @_;
	if (ref $spec ne 'HASH') {
		my $t = kind($doc);
		if ($spec eq 'null_or_number' || $spec eq 'number_or_null') {
			push @$err, "$path $t" if $t ne 'null' && $t ne 'number';
		} elsif ($t ne $spec) {
			push @$err, "$path $t";
		}
		return;
	}
	if (ref $doc ne 'HASH') {
		push @$err, "$path not an object";
		return;
	}
	my %keys = map { $_ => 1 } (keys %$doc, keys %$spec);
	for my $k (sort keys %keys) {
		if (!exists $spec->{$k}) {
			push @$err, "$path.$k extra";
			next;
		}
		if (!exists $doc->{$k}) {
			push @$err, "$path.$k missing";
			next;
		}
		expect_keys($doc->{$k}, $spec->{$k}, "$path.$k", $err);
	}
	return;
}

my %ALERT_SPEC = map { $_ => 'bool' } @ALERTS;
my $STATUS_SPEC = {
	legacy_state => 'null_or_number',
	status => {
		device_info => {
			id => 'string',
			hardware_version => 'string',
			software_version => 'string',
			country_code => 'string',
			bootcount => 'number',
		},
		device_state => { uptime_s => 'number' },
		alerts => \%ALERT_SPEC,
		obstruction_stats => {
			fraction_obstructed => 'number_or_null',
			valid_s => 'number_or_null',
			currently_obstructed => 'bool',
			avg_prolonged_obstruction_duration_s => 'number_or_null',
			avg_prolonged_obstruction_interval_s => 'number_or_null',
		},
		gps_stats => {
			gps_valid => 'bool',
			gps_sats => 'number',
			inhibit_gps => 'bool',
		},
		seconds_to_first_nonempty_slot => 'number_or_null',
		pop_ping_drop_rate => 'number_or_null',
		downlink_throughput_bps => 'number_or_null',
		uplink_throughput_bps => 'number_or_null',
		pop_ping_latency_ms => 'number_or_null',
		stow_requested => 'bool',
		boresight_azimuth_deg => 'number_or_null',
		boresight_elevation_deg => 'number_or_null',
		is_snr_above_noise_floor => 'bool',
		signal_quality => 'number_or_null',
		outage => {
			cause => 'number',
			start_timestamp_ns => 'number',
			duration_ns => 'number',
			did_switch => 'bool',
		},
	},
};

sub hist_len {
	my ($doc) = @_;
	die "history is not an object\n" if ref $doc ne 'HASH';
	die "history current is " . kind($doc->{current}) . "\n"
	    if kind($doc->{current}) ne 'number';
	my $n;
	for my $k (qw(pop_ping_drop_rate pop_ping_latency_ms
	    downlink_throughput_bps uplink_throughput_bps)) {
		die "history $k is not an array\n" if ref $doc->{$k} ne 'ARRAY';
		my $len = @{$doc->{$k}};
		$n = $len if !defined $n;
		die "history $k length $len\n" if $len != $n;
	}
	return $n;
}

sub map_shape {
	my ($doc) = @_;
	die "map is not an object\n" if ref $doc ne 'HASH';
	die "map rows\n" if kind($doc->{num_rows}) ne 'number';
	die "map cols\n" if kind($doc->{num_cols}) ne 'number';
	die "map snr\n" if ref $doc->{snr} ne 'ARRAY';
	my $n = @{$doc->{snr}};
	my $want = $doc->{num_rows} * $doc->{num_cols};
	die "map snr length $n\n" if $n != $want;
	return ($doc->{num_rows} + 0, $doc->{num_cols} + 0, $n);
}

sub fail_out {
	my ($msg) = @_;
	print brief($msg), "\n";
	print "shape mismatch\n";
	exit 1;
}

print "target $target\n";

my $perl_status = eval { perl_call('status') };
fail_out("status perl: $@") if !$perl_status;
my $cpp_status = eval { cpp_call('status') };
fail_out("status cpp: $@") if !$cpp_status;

my @st_err;
expect_keys($perl_status->{doc}, $STATUS_SPEC, '$', \@st_err);
expect_keys($cpp_status, $STATUS_SPEC, '$', \@st_err);
cmp_types($perl_status->{doc}, $cpp_status, '$', \@st_err);
if (@st_err) {
	print "status differ $_\n" for @st_err[0 .. ($#st_err > 19 ? 19 : $#st_err)];
	fail_out('status shape');
}
my %leaves;
count_leaves($perl_status->{doc}, \%leaves);
my $leg_p = kind($perl_status->{doc}{legacy_state});
my $leg_c = kind($cpp_status->{legacy_state});
print "status agree legacy_state=$leg_p/$leg_c",
    " number=", ($leaves{number} // 0),
    " bool=", ($leaves{bool} // 0),
    " string=", ($leaves{string} // 0),
    " null=", ($leaves{null} // 0),
    " unknown=", scalar @{$perl_status->{unknown}},
    " retyped=", scalar @{$perl_status->{retyped}}, "\n";

my $perl_hist = eval { perl_call('history') };
fail_out("history perl: $@") if !$perl_hist;
my $cpp_hist = eval { cpp_call('history') };
fail_out("history cpp: $@") if !$cpp_hist;
my $hn = eval { hist_len($perl_hist->{doc}) };
fail_out("history perl: $@") if !defined $hn;
my $hc = eval { hist_len($cpp_hist) };
fail_out("history cpp: $@") if !defined $hc;
if ($hn != $hc) {
	print "history perl arrays=$hn cpp arrays=$hc\n";
	fail_out('history length');
}
print "history agree arrays=$hn current=number/number",
    " unknown=", scalar @{$perl_hist->{unknown}},
    " retyped=", scalar @{$perl_hist->{retyped}}, "\n";

my $perl_map = eval { perl_call('map') };
fail_out("map perl: $@") if !$perl_map;
my $cpp_map = eval { cpp_call('map') };
fail_out("map cpp: $@") if !$cpp_map;
my ($pr, $pc, $pn) = eval { map_shape($perl_map->{doc}) };
fail_out("map perl: $@") if !defined $pn;
my ($cr, $cc, $cn) = eval { map_shape($cpp_map) };
fail_out("map cpp: $@") if !defined $cn;
if ($pr != $cr || $pc != $cc || $pn != $cn) {
	print "map perl ${pr}x${pc} snr=$pn cpp ${cr}x${cc} snr=$cn\n";
	fail_out('map shape');
}
print "map agree rows=$pr cols=$pc snr=$pn",
    " unknown=", scalar @{$perl_map->{unknown}},
    " retyped=", scalar @{$perl_map->{retyped}}, "\n";
print "shape agreement\n";
exit 0;
