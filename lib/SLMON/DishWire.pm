package SLMON::DishWire;

use strict;
use warnings;

use JSON::PP ();

# Plaintext gRPC for the three dish read calls. The XS bridge stays.

my %WIRE = (
	0 => 'varint',
	1 => 'fixed64',
	2 => 'bytes',
	3 => 'group',
	4 => 'group',
	5 => 'fixed32',
);

my @ALERTS = (
	[1, 'motors_stuck'],
	[2, 'thermal_shutdown'],
	[3, 'thermal_throttle'],
	[4, 'unexpected_location'],
	[5, 'mast_not_near_vertical'],
	[6, 'slow_ethernet_speeds'],
	[8, 'install_pending'],
	[9, 'is_heating'],
	[10, 'power_supply_thermal_throttle'],
	[11, 'is_power_save_idle'],
	[14, 'dbf_telem_stale'],
	[16, 'low_motor_current'],
	[17, 'lower_signal_than_predicted'],
	[18, 'slow_ethernet_speeds_100'],
	[19, 'obstruction_map_reset'],
	[20, 'dish_water_detected'],
	[21, 'router_water_detected'],
	[22, 'upsu_router_port_slow'],
	[23, 'no_ethernet_link'],
);

my %SCHEMA;

my %REQ = (
	status => 1004,
	history => 1007,
	map => 2008,
);

# The dish registers this spelling. The lowercase form is rejected.
sub service_path {
	return '/SpaceX.API.Device.Device/Handle';
}

sub request_bytes {
	my ($op) = @_;
	die "unknown dish op\n" if !defined $op || !exists $REQ{$op};
	return _enc_varint(($REQ{$op} << 3) | 2) . _enc_varint(0);
}

sub grpc_wrap {
	my ($pb) = @_;
	$pb = '' if !defined $pb;
	my $n = length $pb;
	die "grpc message too large\n" if $n > 0xffffffff;
	return pack('C N', 0, $n) . $pb;
}

sub wire_request {
	my ($authority, $op) = @_;
	die "authority must be visible ascii\n"
	    if !defined $authority || $authority !~ /\A[\x21-\x7e]+\z/;
	my $body = grpc_wrap(request_bytes($op));
	return _preface()
	    . _settings_frame()
	    . _http2_frame(1, 0x4, 1, _header_block($authority))
	    . _http2_frame(0, 0x1, 1, $body);
}

# Frames only. The client preface is not a reply.
sub unwrap_http2 {
	my ($buf) = @_;
	die "http2 preface is not a reply\n"
	    if defined $buf && $buf =~ /\APRI \* HTTP\/2\.0\r\n/;
	die "empty http2 reply\n" if !defined $buf || $buf eq '';
	my $data = '';
	my $i = 0;
	my $len = length $buf;
	my $saw = 0;
	while ($i < $len) {
		die "truncated http2 frame\n" if $i + 9 > $len;
		my $flen = unpack('N', "\0" . substr($buf, $i, 3));
		my $type = ord(substr($buf, $i + 3, 1));
		my $flags = ord(substr($buf, $i + 4, 1));
		my $sid = unpack('N', substr($buf, $i + 5, 4)) & 0x7fffffff;
		$i += 9;
		die "truncated http2 frame\n" if $i + $flen > $len;
		my $payload = substr($buf, $i, $flen);
		$i += $flen;
		next if $type != 0;
		die "http2 data on stream 0\n" if $sid == 0;
		if ($flags & 0x8) {
			die "truncated http2 padding\n" if $payload eq '';
			my $pad = ord(substr($payload, 0, 1));
			die "http2 padding longer than the frame\n"
			    if 1 + $pad > length $payload;
			$payload = substr($payload, 1, length($payload) - 1 - $pad);
		}
		$data .= $payload;
		$saw = 1;
	}
	die "http2 reply has no data\n" if !$saw;
	return $data;
}

sub decode_reply {
	my ($frame) = @_;
	die "short grpc frame\n" if !defined $frame || length($frame) < 5;
	my ($comp, $mlen) = unpack('C N', substr($frame, 0, 5));
	die "compressed grpc message\n" if $comp != 0;
	die "truncated grpc message\n" if length($frame) < 5 + $mlen;
	die "grpc frame has trailing bytes\n" if length($frame) != 5 + $mlen;
	my $pb = substr($frame, 5, $mlen);
	my $unknown = [];
	my $retyped = [];
	my $raw = _walk($pb, 'Response', $unknown, $retyped);
	my @hit;
	push @hit, 'status' if exists $raw->{dish_get_status};
	push @hit, 'history' if exists $raw->{dish_get_history};
	push @hit, 'map' if exists $raw->{dish_get_obstruction_map};
	die "response has no dish reply\n" if !@hit;
	die "response has more than one dish reply\n" if @hit > 1;
	my $op = $hit[0];
	my $doc;
	if ($op eq 'status') {
		$doc = _shape_status($raw->{dish_get_status});
	} elsif ($op eq 'history') {
		$doc = _shape_history($raw->{dish_get_history});
	} else {
		$doc = _shape_map($raw->{dish_get_obstruction_map});
	}
	return {
		op => $op,
		doc => $doc,
		unknown => $unknown,
		retyped => $retyped,
	};
}

sub _shape_status {
	my ($raw) = @_;
	$raw ||= {};
	my $info = $raw->{device_info} || {};
	my $dev = $raw->{device_state} || {};
	my $al = $raw->{alerts} || {};
	my $ob = $raw->{obstruction_stats} || {};
	my $gps = $raw->{gps_stats} || {};
	my $out = $raw->{outage} || {};
	my %alerts;
	$alerts{$_->[1]} = _b($al, $_->[1]) for @ALERTS;
	my $legacy;
	$legacy = $raw->{legacy_state} + 0 if exists $raw->{legacy_state};
	return {
		legacy_state => $legacy,
		status => {
			device_info => {
				id => _s($info, 'id'),
				hardware_version => _s($info, 'hardware_version'),
				software_version => _s($info, 'software_version'),
				country_code => _s($info, 'country_code'),
				bootcount => _i($info, 'bootcount'),
			},
			device_state => {
				uptime_s => _i($dev, 'uptime_s'),
			},
			alerts => \%alerts,
			obstruction_stats => {
				fraction_obstructed => _f($ob, 'fraction_obstructed'),
				valid_s => _f($ob, 'valid_s'),
				currently_obstructed => _b($ob, 'currently_obstructed'),
				avg_prolonged_obstruction_duration_s =>
				    _f($ob, 'avg_prolonged_obstruction_duration_s'),
				avg_prolonged_obstruction_interval_s =>
				    _f($ob, 'avg_prolonged_obstruction_interval_s'),
			},
			gps_stats => {
				gps_valid => _b($gps, 'gps_valid'),
				gps_sats => _i($gps, 'gps_sats'),
				inhibit_gps => _b($gps, 'inhibit_gps'),
			},
			seconds_to_first_nonempty_slot =>
			    _f($raw, 'seconds_to_first_nonempty_slot'),
			pop_ping_drop_rate => _f($raw, 'pop_ping_drop_rate'),
			downlink_throughput_bps => _f($raw, 'downlink_throughput_bps'),
			uplink_throughput_bps => _f($raw, 'uplink_throughput_bps'),
			pop_ping_latency_ms => _f($raw, 'pop_ping_latency_ms'),
			stow_requested => _b($raw, 'stow_requested'),
			boresight_azimuth_deg => _f($raw, 'boresight_azimuth_deg'),
			boresight_elevation_deg => _f($raw, 'boresight_elevation_deg'),
			is_snr_above_noise_floor => _b($raw, 'is_snr_above_noise_floor'),
			signal_quality => _f($raw, 'signal_quality'),
			outage => {
				cause => _i($out, 'cause'),
				start_timestamp_ns => _i($out, 'start_timestamp_ns'),
				duration_ns => _i($out, 'duration_ns'),
				did_switch => _b($out, 'did_switch'),
			},
		},
	};
}

sub _shape_history {
	my ($raw) = @_;
	$raw ||= {};
	my @outages = map { _outage($_) } @{$raw->{outages} || []};
	return {
		current => _i($raw, 'current'),
		pop_ping_drop_rate => _flist($raw, 'pop_ping_drop_rate'),
		pop_ping_latency_ms => _flist($raw, 'pop_ping_latency_ms'),
		downlink_throughput_bps => _flist($raw, 'downlink_throughput_bps'),
		uplink_throughput_bps => _flist($raw, 'uplink_throughput_bps'),
		outages => \@outages,
	};
}

sub _shape_map {
	my ($raw) = @_;
	$raw ||= {};
	return {
		num_rows => _i($raw, 'num_rows'),
		num_cols => _i($raw, 'num_cols'),
		snr => _flist($raw, 'snr'),
	};
}

sub _outage {
	my ($raw) = @_;
	$raw ||= {};
	return {
		cause => _i($raw, 'cause'),
		start_timestamp_ns => _i($raw, 'start_timestamp_ns'),
		duration_ns => _i($raw, 'duration_ns'),
		did_switch => _b($raw, 'did_switch'),
	};
}

sub _s {
	my ($raw, $key) = @_;
	return '' if !exists $raw->{$key};
	return $raw->{$key};
}

sub _i {
	my ($raw, $key) = @_;
	return 0 if !exists $raw->{$key};
	return $raw->{$key} + 0;
}

sub _b {
	my ($raw, $key) = @_;
	return JSON::PP::true if exists $raw->{$key} && $raw->{$key};
	return JSON::PP::false;
}

# Missing is the proto3 zero. A present non-finite value is null, matching
# the C++ JSON.
sub _f {
	my ($raw, $key) = @_;
	return 0 if !exists $raw->{$key};
	return _finite_or_null($raw->{$key});
}

sub _flist {
	my ($raw, $key) = @_;
	return [] if !exists $raw->{$key};
	my @out;
	push @out, _finite_or_null($_) for @{$raw->{$key}};
	return \@out;
}

sub _finite_or_null {
	my ($v) = @_;
	return undef if $v != $v;
	return undef if $v =~ /\A-?inf\z/i;
	return $v + 0;
}

sub _walk {
	my ($buf, $msg, $unknown, $retyped) = @_;
	my $schema = $SCHEMA{$msg} or die "no schema $msg\n";
	my %val;
	my $i = 0;
	my $len = length $buf;
	while ($i < $len) {
		my $tag;
		($tag, $i) = _varint_at($buf, $i);
		my $num = $tag >> 3;
		my $wire = $tag & 7;
		die "bad protobuf tag\n" if $num <= 0;
		my $spec = $schema->{$num};
		if (!defined $spec) {
			push @$unknown, {
				message => $msg,
				number => $num,
				wire => $WIRE{$wire} // 'unknown',
			};
			$i = _skip($buf, $i, $wire);
			next;
		}
		my ($kind, $name, $sub) = @$spec;
		# Packed repeated floats are wire type 2. One float is type 5.
		if ($kind eq 'floats' && $wire == 5) {
			my $f;
			($f, $i) = _float_at($buf, $i);
			push @{$val{$name}}, $f;
			next;
		}
		my $expect = _expect_wire($kind);
		if ($wire != $expect) {
			push @$retyped, {
				message => $msg,
				name => $name,
				number => $num,
				wire => $WIRE{$wire} // 'unknown',
				expect => $WIRE{$expect},
			};
			$i = _skip($buf, $i, $wire);
			next;
		}
		if ($kind eq 'varint') {
			($val{$name}, $i) = _varint_at($buf, $i);
		} elsif ($kind eq 'bool') {
			my $n;
			($n, $i) = _varint_at($buf, $i);
			$val{$name} = $n ? 1 : 0;
		} elsif ($kind eq 'float') {
			($val{$name}, $i) = _float_at($buf, $i);
		} elsif ($kind eq 'string' || $kind eq 'floats'
		    || $kind eq 'message' || $kind eq 'messages') {
			my $n;
			($n, $i) = _varint_at($buf, $i);
			die "truncated protobuf\n" if $n < 0 || $i + $n > $len;
			my $blob = substr($buf, $i, $n);
			$i += $n;
			if ($kind eq 'string') {
				$val{$name} = $blob;
			} elsif ($kind eq 'floats') {
				die "packed float length is not a multiple of 4\n" if $n % 4;
				push @{$val{$name}}, unpack('f<*', $blob);
			} elsif ($kind eq 'message') {
				$val{$name} = _walk($blob, $sub, $unknown, $retyped);
			} else {
				push @{$val{$name}}, _walk($blob, $sub, $unknown, $retyped);
			}
		} else {
			die "bad field kind $kind\n";
		}
	}
	return \%val;
}

sub _expect_wire {
	my ($kind) = @_;
	return 2 if $kind eq 'string' || $kind eq 'message'
	    || $kind eq 'messages' || $kind eq 'floats';
	return 5 if $kind eq 'float';
	return 0 if $kind eq 'varint' || $kind eq 'bool';
	die "bad field kind $kind\n";
}

# Bit 63 does not fit a signed IV. Dish timestamps in this code fit below it.
sub _varint_at {
	my ($buf, $i) = @_;
	my $len = length $buf;
	my $n = 0;
	my $shift = 0;
	while (1) {
		die "truncated varint\n" if $i >= $len;
		my $b = ord(substr($buf, $i, 1));
		$i++;
		if ($shift >= 63) {
			die "varint does not fit a signed 64-bit integer\n" if $b != 0;
			return ($n, $i);
		}
		$n += ($b & 0x7f) << $shift;
		return ($n, $i) if ($b & 0x80) == 0;
		$shift += 7;
	}
}

sub _skip {
	my ($buf, $i, $wire) = @_;
	my $len = length $buf;
	if ($wire == 0) {
		my $n;
		($n, $i) = _varint_at($buf, $i);
		return $i;
	}
	if ($wire == 1) {
		die "truncated protobuf\n" if $i + 8 > $len;
		return $i + 8;
	}
	if ($wire == 2) {
		my $n;
		($n, $i) = _varint_at($buf, $i);
		die "truncated protobuf\n" if $n < 0 || $i + $n > $len;
		return $i + $n;
	}
	if ($wire == 5) {
		die "truncated protobuf\n" if $i + 4 > $len;
		return $i + 4;
	}
	die "unsupported protobuf wire type $wire\n";
}

sub _float_at {
	my ($buf, $i) = @_;
	die "truncated protobuf\n" if $i + 4 > length $buf;
	return (unpack('f<', substr($buf, $i, 4)), $i + 4);
}

sub _enc_varint {
	my ($n) = @_;
	die "bad varint\n" if !defined $n || $n < 0;
	my $out = '';
	while ($n >= 128) {
		$out .= pack('C', ($n & 0x7f) | 0x80);
		$n >>= 7;
	}
	$out .= pack('C', $n);
	return $out;
}

sub _preface {
	return "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
}

sub _settings_frame {
	return "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
}

sub _http2_frame {
	my ($type, $flags, $sid, $payload) = @_;
	my $n = length $payload;
	die "http2 frame too large\n" if $n > 0xffffff;
	die "bad http2 stream\n" if $sid < 0 || $sid > 0x7fffffff;
	return substr(pack('N', $n), 1) . pack('C C N', $type, $flags, $sid) . $payload;
}

# Static indexes: 3 POST, 6 http, 4 :path, 1 :authority, 31 content-type.
# Literals are not Huffman-coded. This sketch does not decode Huffman.
sub _header_block {
	my ($authority) = @_;
	return pack('C', 0x80 | 3)
	    . pack('C', 0x80 | 6)
	    . _hpack_lit_name(4, service_path())
	    . _hpack_lit_name(1, $authority)
	    . _hpack_lit_name(31, 'application/grpc')
	    . _hpack_lit_new('te', 'trailers');
}

sub _hpack_lit_name {
	my ($idx, $value) = @_;
	return _hpack_int($idx, 4, 0) . _hpack_raw($value);
}

sub _hpack_lit_new {
	my ($name, $value) = @_;
	return _hpack_int(0, 4, 0) . _hpack_raw($name) . _hpack_raw($value);
}

sub _hpack_raw {
	my ($s) = @_;
	return _hpack_int(length($s), 7, 0) . $s;
}

sub _hpack_int {
	my ($value, $prefix_bits, $high) = @_;
	my $max = (1 << $prefix_bits) - 1;
	if ($value < $max) {
		return pack('C', $high | $value);
	}
	my $out = pack('C', $high | $max);
	$value -= $max;
	while ($value >= 128) {
		$out .= pack('C', ($value & 0x7f) | 0x80);
		$value >>= 7;
	}
	$out .= pack('C', $value);
	return $out;
}

%SCHEMA = (
	Response => {
		3 => ['varint', 'api_version'],
		2004 => ['message', 'dish_get_status', 'DishGetStatusResponse'],
		2006 => ['message', 'dish_get_history', 'DishGetHistoryResponse'],
		2008 => ['message', 'dish_get_obstruction_map', 'DishGetObstructionMapResponse'],
	},
	DeviceInfo => {
		1 => ['string', 'id'],
		2 => ['string', 'hardware_version'],
		3 => ['string', 'software_version'],
		4 => ['string', 'country_code'],
		# In the proto. Not a key in the bridge JSON.
		5 => ['varint', 'utc_offset_s'],
		8 => ['varint', 'bootcount'],
	},
	DeviceState => {
		1 => ['varint', 'uptime_s'],
	},
	DishGpsStats => {
		1 => ['bool', 'gps_valid'],
		2 => ['varint', 'gps_sats'],
		4 => ['bool', 'inhibit_gps'],
	},
	DishObstructionStats => {
		1 => ['float', 'fraction_obstructed'],
		4 => ['float', 'valid_s'],
		5 => ['bool', 'currently_obstructed'],
		6 => ['float', 'avg_prolonged_obstruction_duration_s'],
		7 => ['float', 'avg_prolonged_obstruction_interval_s'],
	},
	DishOutage => {
		1 => ['varint', 'cause'],
		2 => ['varint', 'start_timestamp_ns'],
		3 => ['varint', 'duration_ns'],
		4 => ['bool', 'did_switch'],
	},
	DishGetHistoryResponse => {
		1 => ['varint', 'current'],
		1001 => ['floats', 'pop_ping_drop_rate'],
		1002 => ['floats', 'pop_ping_latency_ms'],
		1003 => ['floats', 'downlink_throughput_bps'],
		1004 => ['floats', 'uplink_throughput_bps'],
		1009 => ['messages', 'outages', 'DishOutage'],
	},
	DishGetObstructionMapResponse => {
		1 => ['varint', 'num_rows'],
		2 => ['varint', 'num_cols'],
		3 => ['floats', 'snr'],
	},
);

$SCHEMA{DishAlerts} = { map { $_->[0] => ['bool', $_->[1]] } @ALERTS };

# Field 1006 is not in the proto. The bridge reads it as legacy_state.
$SCHEMA{DishGetStatusResponse} = {
	1 => ['message', 'device_info', 'DeviceInfo'],
	2 => ['message', 'device_state', 'DeviceState'],
	1002 => ['float', 'seconds_to_first_nonempty_slot'],
	1003 => ['float', 'pop_ping_drop_rate'],
	1004 => ['message', 'obstruction_stats', 'DishObstructionStats'],
	1005 => ['message', 'alerts', 'DishAlerts'],
	1006 => ['varint', 'legacy_state'],
	1007 => ['float', 'downlink_throughput_bps'],
	1008 => ['float', 'uplink_throughput_bps'],
	1009 => ['float', 'pop_ping_latency_ms'],
	1010 => ['bool', 'stow_requested'],
	1011 => ['float', 'boresight_azimuth_deg'],
	1012 => ['float', 'boresight_elevation_deg'],
	1014 => ['message', 'outage', 'DishOutage'],
	1015 => ['message', 'gps_stats', 'DishGpsStats'],
	1018 => ['bool', 'is_snr_above_noise_floor'],
	1057 => ['float', 'signal_quality'],
};

1;
