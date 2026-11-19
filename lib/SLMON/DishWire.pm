package SLMON::DishWire;

use strict;
use warnings;

use IO::Socket::INET;
use JSON::PP ();
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Time::HiRes ();

# Plaintext gRPC for the three dish read calls. The XS bridge stays.
# call() is one RPC on a 5 second deadline. It sends SETTINGS (push off,
# a 1 MiB stream window, 64 KiB frames), a connection WINDOW_UPDATE, the
# Handle headers, and one DATA frame. It acks peer SETTINGS, replenishes
# both flow-control windows, and returns decode_reply when grpc-status is 0.

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

# Protobuf sign-extends a negative int32 to ten bytes, so bit 63 can be set.
# The tenth byte is only 0 or 1. Anything wider is not a 64-bit varint.
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
			die "varint does not fit a 64-bit integer\n" if ($b & 0xfe) != 0;
			$n += (1 << 63) if $b & 1;
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

# Above the default 65535 connection window. The map does not fit in that.
my $STREAM_WIN = 1024 * 1024;
my $MAX_FRAME = 65536;
my $MAX_REPLY = 16 * 1024 * 1024;
my $DEADLINE_S = 5;

sub call {
	my ($target, $op) = @_;
	die "unknown dish op\n" if !defined $op || !exists $REQ{$op};
	die "authority must be visible ascii\n"
	    if !defined $target || $target !~ /\A[\x21-\x7e]+\z/;
	my ($host, $port) = _target($target);
	my $deadline = Time::HiRes::time() + $DEADLINE_S;
	my $sock = _connect_dish($host, $port, $deadline);
	local $SIG{PIPE} = 'IGNORE';
	my $reply;
	my $err;
	my $ok = eval {
		$reply = _exchange($sock, $target, $op, $deadline);
		1;
	};
	$err = $@ if !$ok;
	close $sock;
	die $err if !$ok;
	return $reply;
}

sub _target {
	my ($target) = @_;
	die "dish target must be host:port\n" if $target !~ /\A([^:]+):([0-9]+)\z/;
	my $port = int($2);
	die "dish port\n" if $port < 1 || $port > 65535;
	return ($1, $port);
}

sub _connect_dish {
	my ($host, $port, $deadline) = @_;
	my $left = $deadline - Time::HiRes::time();
	die "dish deadline exceeded\n" if $left <= 0;
	my $sock = IO::Socket::INET->new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => $left,
	);
	if (!$sock) {
		my $why = $@ || $!;
		$why =~ s/\s+\z//;
		$why =~ s/\s+at \S+ line \d+\.?//g;
		die "connect: $why\n";
	}
	$sock->setsockopt(IPPROTO_TCP, TCP_NODELAY, pack('i', 1))
	    or die "TCP_NODELAY: $!\n";
	binmode $sock;
	return $sock;
}

sub _exchange {
	my ($sock, $authority, $op, $deadline) = @_;
	my $settings = pack('nNnNnN', 2, 0, 4, $STREAM_WIN, 5, $MAX_FRAME);
	my $bytes = _preface()
	    . _http2_frame(4, 0, 0, $settings)
	    . _http2_frame(8, 0, 0, pack('N', $STREAM_WIN))
	    . _http2_frame(1, 0x4, 1, _call_headers($authority))
	    . _http2_frame(0, 0x1, 1, grpc_wrap(request_bytes($op)));
	_write_all($sock, $bytes, $deadline, 0);

	my $buf = '';
	my $dyn = _hpack_new();
	my $data = '';
	my $hblock = '';
	my $hopen = 0;
	my $hend = 0;
	my $http_status;
	my $ctype;
	my $grpc_status;
	my $grpc_message = '';
	my $done = 0;
	my $conn_owed = 0;
	my $stream_owed = 0;
	while (!$done) {
		my ($type, $flags, $sid, $payload) =
		    _read_frame($sock, \$buf, $deadline);
		if ($type == 4) {
			if ($flags & 0x1) {
				die "http2 settings ack has a payload\n" if $payload ne '';
				next;
			}
			die "http2 settings on a stream\n" if $sid != 0;
			_apply_peer_settings($dyn, $payload);
			_write_all($sock, _http2_frame(4, 0x1, 0, ''), $deadline, 0);
		} elsif ($type == 8) {
			die "truncated window update\n" if length($payload) != 4;
			my $inc = unpack('N', $payload) & 0x7fffffff;
			die "http2 window update is zero\n" if $inc == 0;
		} elsif ($type == 6) {
			die "truncated ping\n" if length($payload) != 8;
			if (($flags & 0x1) == 0) {
				_write_all($sock, _http2_frame(6, 0x1, 0, $payload),
				    $deadline, 0);
			}
		} elsif ($type == 7) {
			die "truncated goaway\n" if length($payload) < 8;
			my ($code) = unpack('x4 N', $payload);
			die "http2 goaway $code\n";
		} elsif ($type == 3) {
			die "truncated reset\n" if length($payload) != 4;
			my ($code) = unpack('N', $payload);
			die "http2 reset $code\n";
		} elsif ($type == 0) {
			die "http2 data on stream 0\n" if $sid == 0;
			die "http2 data on the wrong stream\n" if $sid != 1;
			# Padding counts against the window. Restore the frame length.
			$conn_owed += length($payload);
			$stream_owed += length($payload);
			_flush_windows($sock, \$conn_owed, \$stream_owed, $deadline);
			if ($flags & 0x8) {
				die "truncated http2 padding\n" if $payload eq '';
				my $pad = ord(substr($payload, 0, 1));
				die "http2 padding longer than the frame\n"
				    if 1 + $pad > length $payload;
				$payload = substr($payload, 1, length($payload) - 1 - $pad);
			}
			$data .= $payload;
			die "grpc reply too large\n" if length($data) > $MAX_REPLY;
			$done = 1 if $flags & 0x1;
		} elsif ($type == 1 || $type == 9) {
			if ($type == 9) {
				die "http2 continuation without headers\n" if !$hopen;
			} else {
				die "http2 headers while a block is open\n" if $hopen;
				die "http2 headers on stream 0\n" if $sid == 0;
				die "http2 headers on the wrong stream\n" if $sid != 1;
				$hend = ($flags & 0x1) ? 1 : 0;
				$payload = _header_fragment($flags, $payload);
			}
			$hblock .= $payload;
			die "http2 header block too large\n" if length($hblock) > 65536;
			if ($flags & 0x4) {
				my $headers = _hpack_decode($hblock, $dyn);
				$hblock = '';
				$hopen = 0;
				_take_headers($headers, \$http_status, \$ctype,
				    \$grpc_status, \$grpc_message);
				$done = 1 if $hend;
			} else {
				$hopen = 1;
			}
		} elsif ($type == 5) {
			die "http2 push\n";
		}
	}
	die 'http status ' . (defined $http_status ? $http_status : 'missing') . "\n"
	    if !defined $http_status || $http_status ne '200';
	if (defined $ctype && $ctype !~ m{\Aapplication/grpc(?:\+proto)?\b}) {
		die "content-type is not grpc\n";
	}
	die "missing grpc-status\n" if !defined $grpc_status;
	if ($grpc_status ne '0') {
		$grpc_message =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
		$grpc_message =~ s/[^\x20-\x7e]/./g;
		$grpc_message = substr($grpc_message, 0, 80);
		die "grpc status $grpc_status $grpc_message\n";
	}
	return decode_reply($data);
}

# Same header block as wire_request, plus the deadline the C++ client sets.
sub _call_headers {
	my ($authority) = @_;
	return _header_block($authority) . _hpack_lit_new('grpc-timeout', '5S');
}

sub _header_fragment {
	my ($flags, $payload) = @_;
	my $i = 0;
	my $end = length $payload;
	if ($flags & 0x8) {
		die "truncated http2 padding\n" if $payload eq '';
		my $pad = ord(substr($payload, 0, 1));
		die "http2 padding longer than the frame\n"
		    if 1 + $pad > length $payload;
		$i = 1;
		$end -= $pad;
	}
	if ($flags & 0x20) {
		die "truncated http2 priority\n" if $end - $i < 5;
		$i += 5;
	}
	return substr($payload, $i, $end - $i);
}

sub _flush_windows {
	my ($sock, $conn, $stream, $deadline) = @_;
	return if $$conn == 0 && $$stream == 0;
	my $out = '';
	if ($$conn) {
		die "http2 window increment\n" if $$conn > 0x7fffffff;
		$out .= _http2_frame(8, 0, 0, pack('N', $$conn));
		$$conn = 0;
	}
	if ($$stream) {
		die "http2 window increment\n" if $$stream > 0x7fffffff;
		$out .= _http2_frame(8, 0, 1, pack('N', $$stream));
		$$stream = 0;
	}
	# The peer may already have finished. The bytes already queued still read.
	_write_all($sock, $out, $deadline, 1);
	return;
}

sub _apply_peer_settings {
	my ($dyn, $payload) = @_;
	die "http2 settings length\n" if length($payload) % 6;
	for (my $i = 0; $i < length $payload; $i += 6) {
		my ($id, $val) = unpack('n N', substr($payload, $i, 6));
		if ($id == 1) {
			die "hpack table size\n" if $val > 1048576;
			$dyn->{cap} = $val;
			$dyn->{max} = $val if $dyn->{max} > $val;
			_hpack_evict($dyn);
		}
	}
	return;
}

sub _take_headers {
	my ($headers, $http, $ctype, $status, $message) = @_;
	for my $h (@$headers) {
		my $name = lc $h->[0];
		if ($name eq ':status') {
			$$http = $h->[1] if !defined $$http;
		} elsif ($name eq 'content-type') {
			$$ctype = $h->[1] if !defined $$ctype;
		} elsif ($name eq 'grpc-status') {
			$$status = $h->[1];
		} elsif ($name eq 'grpc-message') {
			$$message = $h->[1];
		}
	}
	return;
}

sub _read_frame {
	my ($sock, $buf, $deadline) = @_;
	_fill($sock, $buf, 9, $deadline);
	my $head = substr($$buf, 0, 9, '');
	my $flen = unpack('N', "\0" . substr($head, 0, 3));
	my $type = ord(substr($head, 3, 1));
	my $flags = ord(substr($head, 4, 1));
	my $sid = unpack('N', substr($head, 5, 4)) & 0x7fffffff;
	die "http2 frame too large\n" if $flen > $MAX_FRAME;
	_fill($sock, $buf, $flen, $deadline) if $flen;
	my $payload = $flen ? substr($$buf, 0, $flen, '') : '';
	return ($type, $flags, $sid, $payload);
}

sub _fill {
	my ($sock, $buf, $need, $deadline) = @_;
	while (length($$buf) < $need) {
		my $left = $deadline - Time::HiRes::time();
		die "dish deadline exceeded\n" if $left <= 0;
		my $rin = '';
		vec($rin, fileno($sock), 1) = 1;
		my $n = select($rin, undef, undef, $left);
		die "dish deadline exceeded\n" if !$n;
		my $want = $need - length($$buf);
		$want = 16384 if $want < 16384;
		my $got = sysread($sock, my $chunk, $want);
		if (!defined $got) {
			next if $!{EINTR};
			die "dish read: $!\n";
		}
		die "dish connection closed\n" if $got == 0;
		$$buf .= $chunk;
	}
	return;
}

sub _write_all {
	my ($sock, $bytes, $deadline, $optional) = @_;
	my $off = 0;
	my $len = length $bytes;
	while ($off < $len) {
		my $left = $deadline - Time::HiRes::time();
		die "dish deadline exceeded\n" if $left <= 0;
		my $win = '';
		vec($win, fileno($sock), 1) = 1;
		my $n = select(undef, $win, undef, $left);
		die "dish deadline exceeded\n" if !$n;
		my $w = syswrite($sock, $bytes, $len - $off, $off);
		if (!defined $w) {
			next if $!{EINTR};
			return 0 if $optional && ($!{EPIPE} || $!{ECONNRESET});
			die "dish write: $!\n";
		}
		die "dish write: short\n" if $w == 0;
		$off += $w;
	}
	return 1;
}

# RFC 7541 static table, index 1 first. Values are the ones the table stores.
my @HPACK_STATIC = (
	[':authority', ''],
	[':method', 'GET'],
	[':method', 'POST'],
	[':path', '/'],
	[':path', '/index.html'],
	[':scheme', 'http'],
	[':scheme', 'https'],
	[':status', '200'],
	[':status', '204'],
	[':status', '206'],
	[':status', '304'],
	[':status', '400'],
	[':status', '404'],
	[':status', '500'],
	['accept-charset', ''],
	['accept-encoding', 'gzip, deflate'],
	['accept-language', ''],
	['accept-ranges', ''],
	['accept', ''],
	['access-control-allow-origin', ''],
	['age', ''],
	['allow', ''],
	['authorization', ''],
	['cache-control', ''],
	['content-disposition', ''],
	['content-encoding', ''],
	['content-language', ''],
	['content-length', ''],
	['content-location', ''],
	['content-range', ''],
	['content-type', ''],
	['cookie', ''],
	['date', ''],
	['etag', ''],
	['expect', ''],
	['expires', ''],
	['from', ''],
	['host', ''],
	['if-match', ''],
	['if-modified-since', ''],
	['if-none-match', ''],
	['if-range', ''],
	['if-unmodified-since', ''],
	['last-modified', ''],
	['link', ''],
	['location', ''],
	['max-forwards', ''],
	['proxy-authenticate', ''],
	['proxy-authorization', ''],
	['range', ''],
	['referer', ''],
	['refresh', ''],
	['retry-after', ''],
	['server', ''],
	['set-cookie', ''],
	['strict-transport-security', ''],
	['transfer-encoding', ''],
	['user-agent', ''],
	['vary', ''],
	['via', ''],
	['www-authenticate', ''],
);

sub _hpack_new {
	return {
		cap => 4096,
		max => 4096,
		size => 0,
		ent => [],
	};
}

sub _hpack_evict {
	my ($dyn) = @_;
	while ($dyn->{size} > $dyn->{max} && @{$dyn->{ent}}) {
		my $old = pop @{$dyn->{ent}};
		$dyn->{size} -= $old->[2];
	}
	return;
}

sub _hpack_add {
	my ($dyn, $name, $value) = @_;
	my $sz = length($name) + length($value) + 32;
	if ($sz > $dyn->{max}) {
		$dyn->{ent} = [];
		$dyn->{size} = 0;
		return;
	}
	while ($dyn->{size} + $sz > $dyn->{max} && @{$dyn->{ent}}) {
		my $old = pop @{$dyn->{ent}};
		$dyn->{size} -= $old->[2];
	}
	unshift @{$dyn->{ent}}, [$name, $value, $sz];
	$dyn->{size} += $sz;
	return;
}

sub _hpack_resize {
	my ($dyn, $max) = @_;
	die "hpack table size\n" if $max > $dyn->{cap};
	$dyn->{max} = $max;
	_hpack_evict($dyn);
	return;
}

sub _hpack_lookup {
	my ($dyn, $idx) = @_;
	die "hpack index\n" if $idx <= 0;
	if ($idx <= @HPACK_STATIC) {
		return @{$HPACK_STATIC[$idx - 1]};
	}
	my $di = $idx - @HPACK_STATIC - 1;
	die "hpack index\n" if $di < 0 || $di > $#{$dyn->{ent}};
	return ($dyn->{ent}[$di][0], $dyn->{ent}[$di][1]);
}

sub _hpack_int_at {
	my ($buf, $i, $prefix) = @_;
	die "truncated hpack\n" if $i >= length $buf;
	my $max = (1 << $prefix) - 1;
	my $b = ord(substr($buf, $i, 1));
	$i++;
	my $n = $b & $max;
	return ($n, $i) if $n < $max;
	my $m = 0;
	while (1) {
		die "truncated hpack\n" if $i >= length $buf;
		die "hpack integer too long\n" if $m > 28;
		my $c = ord(substr($buf, $i, 1));
		$i++;
		$n += ($c & 0x7f) << $m;
		return ($n, $i) if ($c & 0x80) == 0;
		$m += 7;
	}
}

sub _hpack_str {
	my ($buf, $i) = @_;
	die "truncated hpack\n" if $i >= length $buf;
	my $huff = ord(substr($buf, $i, 1)) & 0x80;
	my ($n, $ni) = _hpack_int_at($buf, $i, 7);
	$i = $ni;
	die "hpack string too large\n" if $n > 65536;
	die "truncated hpack\n" if $i + $n > length $buf;
	my $raw = substr($buf, $i, $n);
	$i += $n;
	return ($huff ? _huff_decode($raw) : $raw, $i);
}

sub _hpack_decode {
	my ($buf, $dyn) = @_;
	$dyn ||= _hpack_new();
	my @headers;
	my $i = 0;
	my $len = length $buf;
	my $sizing = 1;
	while ($i < $len) {
		my $b = ord(substr($buf, $i, 1));
		if ($b & 0x80) {
			$sizing = 0;
			my ($idx, $ni) = _hpack_int_at($buf, $i, 7);
			$i = $ni;
			my ($name, $value) = _hpack_lookup($dyn, $idx);
			push @headers, [$name, $value];
		} elsif ($b & 0x40) {
			$sizing = 0;
			my ($idx, $ni) = _hpack_int_at($buf, $i, 6);
			$i = $ni;
			my $name;
			if ($idx) {
				($name) = _hpack_lookup($dyn, $idx);
			} else {
				($name, $i) = _hpack_str($buf, $i);
			}
			my $value;
			($value, $i) = _hpack_str($buf, $i);
			push @headers, [$name, $value];
			_hpack_add($dyn, $name, $value);
		} elsif ($b & 0x20) {
			die "hpack table update\n" if !$sizing;
			my ($sz, $ni) = _hpack_int_at($buf, $i, 5);
			$i = $ni;
			_hpack_resize($dyn, $sz);
		} else {
			$sizing = 0;
			my ($idx, $ni) = _hpack_int_at($buf, $i, 4);
			$i = $ni;
			my $name;
			if ($idx) {
				($name) = _hpack_lookup($dyn, $idx);
			} else {
				($name, $i) = _hpack_str($buf, $i);
			}
			my $value;
			($value, $i) = _hpack_str($buf, $i);
			push @headers, [$name, $value];
		}
	}
	return \@headers;
}

# RFC 7541 Appendix B. Each symbol is a big-endian code and a bit length.
# Symbol 256 is EOS. The hex is 257 entries, 5 bytes each.
my $HUFF_HEX = '00001ff80d007fffd8170fffffe21c0fffffe31c0fffffe41c0fffffe51c0fffffe61c0fffffe71c0fffffe81c00ffffea183ffffffc1e0fffffe91c0fffffea1c3ffffffd1e0fffffeb1c0fffffec1c0fffffed1c0fffffee1c0fffffef1c0ffffff01c0ffffff11c0ffffff21c3ffffffe1e0ffffff31c0ffffff41c0ffffff51c0ffffff61c0ffffff71c0ffffff81c0ffffff91c0ffffffa1c0ffffffb1c0000001406000003f80a000003f90a00000ffa0c00001ff90d0000001506000000f808000007fa0b000003fa0a000003fb0a000000f908000007fb0b000000fa0800000016060000001706000000180600000000050000000105000000020500000019060000001a060000001b060000001c060000001d060000001e060000001f060000005c07000000fb0800007ffc0f000000200600000ffb0c000003fc0a00001ffa0d00000021060000005d070000005e070000005f0700000060070000006107000000620700000063070000006407000000650700000066070000006707000000680700000069070000006a070000006b070000006c070000006d070000006e070000006f07000000700700000071070000007207000000fc080000007307000000fd0800001ffb0d0007fff01300001ffc0d00003ffc0e000000220600007ffd0f00000003050000002306000000040500000024060000000505000000250600000026060000002706000000060500000074070000007507000000280600000029060000002a0600000007050000002b0600000076070000002c06000000080500000009050000002d060000007707000000780700000079070000007a070000007b0700007ffe0f000007fc0b00003ffd0e00001ffd0d0ffffffc1c000fffe614003fffd216000fffe714000fffe814003fffd316003fffd416003fffd516007fffd917003fffd616007fffda17007fffdb17007fffdc17007fffdd17007fffde1700ffffeb18007fffdf1700ffffec1800ffffed18003fffd716007fffe01700ffffee18007fffe117007fffe217007fffe317007fffe417001fffdc15003fffd816007fffe517003fffd916007fffe617007fffe71700ffffef18003fffda16001fffdd15000fffe914003fffdb16003fffdc16007fffe817007fffe917001fffde15007fffea17003fffdd16003fffde1600fffff018001fffdf15003fffdf16007fffeb17007fffec17001fffe015001fffe115003fffe016001fffe215007fffed17003fffe116007fffee17007fffef17000fffea14003fffe216003fffe316003fffe416007ffff017003fffe516003fffe616007ffff11703ffffe01a03ffffe11a000fffeb140007fff113003fffe716007ffff217003fffe81601ffffec1903ffffe21a03ffffe31a03ffffe41a07ffffde1b07ffffdf1b03ffffe51a00fffff11801ffffed190007fff213001fffe31503ffffe61a07ffffe01b07ffffe11b03ffffe71a07ffffe21b00fffff218001fffe415001fffe51503ffffe81a03ffffe91a0ffffffd1c07ffffe31b07ffffe41b07ffffe51b000fffec1400fffff318000fffed14001fffe615003fffe916001fffe715001fffe815007ffff317003fffea16003fffeb1601ffffee1901ffffef1900fffff41800fffff51803ffffea1a007ffff41703ffffeb1a07ffffe61b03ffffec1a03ffffed1a07ffffe71b07ffffe81b07ffffe91b07ffffea1b07ffffeb1b0ffffffe1c07ffffec1b07ffffed1b07ffffee1b07ffffef1b07fffff01b03ffffee1a3fffffff1e';
my $HUFF_ROOT;

sub _huff_init {
	return if $HUFF_ROOT;
	my $raw = pack('H*', $HUFF_HEX);
	die "huffman table\n" if length($raw) != 257 * 5;
	my $root = [];
	for my $sym (0 .. 256) {
		my ($code, $bits) = unpack('NC', substr($raw, $sym * 5, 5));
		die "huffman length\n" if $bits < 1 || $bits > 30;
		my $node = $root;
		for (my $b = $bits - 1; $b >= 0; $b--) {
			my $bit = ($code >> $b) & 1;
			if ($b == 0) {
				die "huffman prefix\n" if defined $node->[$bit];
				$node->[$bit] = $sym;
			} elsif (!defined $node->[$bit]) {
				$node = $node->[$bit] = [];
			} elsif (!ref $node->[$bit]) {
				die "huffman prefix\n";
			} else {
				$node = $node->[$bit];
			}
		}
	}
	$HUFF_ROOT = $root;
	return;
}

sub _huff_decode {
	my ($bytes) = @_;
	_huff_init();
	my $node = $HUFF_ROOT;
	my $out = '';
	my $pend = 0;
	my $ones = 0;
	my $len = length $bytes;
	for (my $i = 0; $i < $len; $i++) {
		my $byte = ord(substr($bytes, $i, 1));
		for (my $b = 7; $b >= 0; $b--) {
			my $bit = ($byte >> $b) & 1;
			my $next = $node->[$bit];
			die "bad huffman code\n" if !defined $next;
			if (ref $next) {
				$node = $next;
				$pend++;
				if ($bit == 1 && $ones >= 0) {
					$ones++;
				} else {
					$ones = -1;
				}
			} else {
				die "huffman eos\n" if $next == 256;
				$out .= chr($next);
				$node = $HUFF_ROOT;
				$pend = 0;
				$ones = 0;
			}
		}
	}
	return $out if $pend == 0;
	die "bad huffman padding\n" if $pend > 7 || $ones != $pend;
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
