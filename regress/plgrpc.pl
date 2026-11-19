#!/usr/bin/perl

use strict;
use warnings;
use FindBin;

use lib "$FindBin::Bin/../lib";
use IO::Socket::INET;
use JSON::PP ();
use SLMON ();
use SLMON::DishWire;
use SLMON::History;
use SLMON::StatusMap;

# Fixtures are protoc --encode of proto/spacex_device.proto, plus a few
# short messages checked with protoc --decode_raw. The live dish was not
# contacted. The timestamp is 2^53+3 so a float decoder cannot pass.

my $fail = 0;
my $n = 0;

sub ok {
	my ($cond, $name) = @_;
	$n++;
	if ($cond) {
		print "ok $n - $name\n";
	} else {
		print "not ok $n - $name\n";
		$fail++;
	}
	return;
}

sub dies {
	my ($code, $re, $name) = @_;
	my $err = '';
	my $ok = eval { $code->(); 1 };
	$err = $@ if !$ok;
	ok(!$ok && $err =~ $re, $name);
	return;
}

sub T { return JSON::PP::true; }
sub F { return JSON::PP::false; }

sub _eq {
	my ($a, $b, $path, $err) = @_;
	$path //= '$';
	if (!defined $a || !defined $b) {
		return 1 if !defined $a && !defined $b;
		$$err = "$path undef";
		return 0;
	}
	if (ref($a) eq 'JSON::PP::Boolean' || ref($b) eq 'JSON::PP::Boolean') {
		if (ref($a) ne 'JSON::PP::Boolean' || ref($b) ne 'JSON::PP::Boolean') {
			$$err = "$path bool";
			return 0;
		}
		return 1 if (($a ? 1 : 0) == ($b ? 1 : 0));
		$$err = "$path bool value";
		return 0;
	}
	if (ref $a eq 'HASH' || ref $b eq 'HASH') {
		if (ref $a ne 'HASH' || ref $b ne 'HASH') {
			$$err = "$path hash";
			return 0;
		}
		my %keys = map { $_ => 1 } (keys %$a, keys %$b);
		for my $k (sort keys %keys) {
			return 0 if !_eq($a->{$k}, $b->{$k}, "$path.$k", $err);
		}
		return 1;
	}
	if (ref $a eq 'ARRAY' || ref $b eq 'ARRAY') {
		if (ref $a ne 'ARRAY' || ref $b ne 'ARRAY') {
			$$err = "$path array";
			return 0;
		}
		if (@$a != @$b) {
			$$err = "$path length";
			return 0;
		}
		for my $i (0 .. $#$a) {
			return 0 if !_eq($a->[$i], $b->[$i], "$path\[$i]", $err);
		}
		return 1;
	}
	if (ref $a || ref $b) {
		$$err = "$path ref";
		return 0;
	}
	if ($a =~ /\A-?\d+\z/ && $b =~ /\A-?\d+\z/) {
		return 1 if "$a" eq "$b";
		$$err = "$path int $a vs $b";
		return 0;
	}
	if ($a =~ /\A-?\d+(?:\.\d+)?\z/ && $b =~ /\A-?\d+(?:\.\d+)?\z/) {
		return 1 if $a == $b;
		$$err = "$path num $a vs $b";
		return 0;
	}
	return 1 if "$a" eq "$b";
	$$err = "$path str";
	return 0;
}

sub same {
	my ($got, $exp, $name) = @_;
	my $err = '';
	my $good = _eq($got, $exp, '$', \$err);
	if (!$good) {
		print STDERR "mismatch $err\n";
		print STDERR "got ", SLMON::json_encode($got), "\n";
		print STDERR "exp ", SLMON::json_encode($exp), "\n";
	}
	ok($good, $name);
	return;
}

sub pb {
	my ($hex) = @_;
	$hex =~ s/\s+//g;
	return pack('H*', $hex);
}

sub grpc_frame {
	my ($body) = @_;
	return pack('C N', 0, length $body) . $body;
}

sub http2_frame {
	my ($type, $flags, $sid, $payload) = @_;
	my $n = length $payload;
	return substr(pack('N', $n), 1) . pack('C C N', $type, $flags, $sid) . $payload;
}

my %REQ = (
	status => 'e23e00',
	history => 'fa3e00',
	map => 'c27d00',
);

for my $op (sort keys %REQ) {
	ok(unpack('H*', SLMON::DishWire::request_bytes($op)) eq $REQ{$op},
	    "$op request bytes");
}

ok(SLMON::DishWire::service_path() eq '/SpaceX.API.Device.Device/Handle',
    'service path');

my $hpack = '838604202f5370616365582e4150492e4465766963652e446576696365'
    . '2f48616e646c6501123139322e3136382e3130302e313a393230300f1010'
    . '6170706c69636174696f6e2f677270630002746508747261696c657273';

my $preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
for my $op (qw(status history map)) {
	my $wire = SLMON::DishWire::wire_request('192.168.100.1:9200', $op);
	ok(substr($wire, 0, length $preface) eq $preface, "$op preface");
	my $rest = substr($wire, length $preface);
	my @fr;
	my $i = 0;
	while ($i < length $rest) {
		my $flen = unpack('N', "\0" . substr($rest, $i, 3));
		my $type = ord(substr($rest, $i + 3, 1));
		my $flags = ord(substr($rest, $i + 4, 1));
		my $sid = unpack('N', substr($rest, $i + 5, 4));
		my $payload = substr($rest, $i + 9, $flen);
		push @fr, [$type, $flags, $sid, $payload];
		$i += 9 + $flen;
	}
	ok(@fr == 3, "$op writes three frames");
	ok($fr[0][0] == 4 && $fr[0][1] == 0 && $fr[0][2] == 0 && $fr[0][3] eq '',
	    "$op empty settings");
	ok($fr[1][0] == 1 && $fr[1][1] == 4 && $fr[1][2] == 1, "$op headers frame");
	ok(unpack('H*', $fr[1][3]) eq $hpack, "$op header block");
	my $body = pb($REQ{$op});
	ok($fr[2][0] == 0 && $fr[2][1] == 1 && $fr[2][2] == 1
	    && $fr[2][3] eq pack('C N', 0, length $body) . $body,
	    "$op data frame");
}

dies(sub { SLMON::DishWire::request_bytes('reboot') }, qr/unknown dish op/,
    'unknown op');
dies(sub { SLMON::DishWire::wire_request('not a host', 'status') },
    qr/authority/, 'authority is visible ascii');

my $status_pb = pb('1801a27d8d010a190a07646973682d757412036877311a0373773122025553'
    . '400712020864d53e00004041dd3e0000803ee23e160d0000003f250000804028013500000041'
    . '3d00008041ea3e0408011801fd3e00008044853f000080438d3f0000a0419d3f00003443a53f'
    . '00003442b23f1108021083808080808080101880e497d012ba3f040801100cd03f018d420000'
    . '003f');
my $history_pb = pb('b27d5d0804ca3e1000000000000000000000803f0000003fd23e1000002041'
    . '000030410000404100005041da3e100000c8420000c8420000c8420000c842e23e1000004842'
    . '0000484200004842000048428a3f0c08031032188094ebdc032001');
my $map_pb = pb('c27d16080210021a10000080bf0000803f000000000000803f');

my @alert_names = qw(
    motors_stuck thermal_shutdown thermal_throttle unexpected_location
    mast_not_near_vertical slow_ethernet_speeds install_pending is_heating
    power_supply_thermal_throttle is_power_save_idle dbf_telem_stale
    low_motor_current lower_signal_than_predicted slow_ethernet_speeds_100
    obstruction_map_reset dish_water_detected router_water_detected
    upsu_router_port_slow no_ethernet_link
);
my %alerts = map { $_ => F() } @alert_names;
$alerts{motors_stuck} = T();
$alerts{thermal_throttle} = T();

my $status_exp = {
	legacy_state => undef,
	status => {
		device_info => {
			id => 'dish-ut',
			hardware_version => 'hw1',
			software_version => 'sw1',
			country_code => 'US',
			bootcount => 7,
		},
		device_state => { uptime_s => 100 },
		alerts => \%alerts,
		obstruction_stats => {
			fraction_obstructed => 0.5,
			valid_s => 4,
			currently_obstructed => T(),
			avg_prolonged_obstruction_duration_s => 8,
			avg_prolonged_obstruction_interval_s => 16,
		},
		gps_stats => {
			gps_valid => T(),
			gps_sats => 12,
			inhibit_gps => F(),
		},
		seconds_to_first_nonempty_slot => 12,
		pop_ping_drop_rate => 0.25,
		downlink_throughput_bps => 1024,
		uplink_throughput_bps => 256,
		pop_ping_latency_ms => 20,
		stow_requested => F(),
		boresight_azimuth_deg => 180,
		boresight_elevation_deg => 45,
		is_snr_above_noise_floor => T(),
		signal_quality => 0.5,
		outage => {
			cause => 2,
			start_timestamp_ns => 9007199254740995,
			duration_ns => 5000000000,
			did_switch => F(),
		},
	},
};

my $st = SLMON::DishWire::decode_reply(grpc_frame($status_pb));
ok($st->{op} eq 'status', 'status op');
ok(@{$st->{unknown}} == 0 && @{$st->{retyped}} == 0, 'status shape is known');
ok(!exists $st->{doc}{api_version}, 'api_version is not a hash key');
ok(!exists $st->{doc}{status}{device_info}{utc_offset_s},
    'utc_offset_s is not a hash key');
same($st->{doc}, $status_exp, 'status hash');

my $now = 1_700_000_000;
my $row = SLMON::StatusMap::status_row($st->{doc}, $now);
ok($row->{ping_drop_rate} == 0.25, 'status row drop');
ok($row->{ping_latency_ms} == 20, 'status row latency');
ok($row->{obstr_fraction} == 0.5, 'status row obstruction');
ok($row->{obstr_valid_s} == 4, 'status row valid seconds');
ok($row->{downlink_bps} == 1024 && $row->{uplink_bps} == 256, 'status row throughput');
ok(!defined $row->{state}, 'null legacy_state is not a state');
ok($row->{snr} == 0.5, 'status row snr');
ok($row->{uptime_s} == 100, 'status row uptime');
ok($row->{currently_obstructed} == 1, 'status row obstructed');
ok($row->{obstruction_duration} == 8 && $row->{obstruction_interval} == 16,
    'status row obstruction times');
ok($row->{direction_azimuth} == 180 && $row->{direction_elevation} == 45,
    'status row boresight');
ok($row->{is_snr_above_noise_floor} == 1, 'status row snr flag');
ok($row->{gps_ready} == 1 && $row->{gps_enabled} == 1 && $row->{gps_sats} == 12,
    'status row gps');
ok($row->{alerts_bitfield} == ((1 << 1) | (1 << 3)), 'motors_stuck and thermal_throttle');
ok($row->{seconds_to_first_nonempty_slot} == 12, 'status row first slot');

my $info = SLMON::StatusMap::dish_info($st->{doc}, $now);
ok($info->{device_id} eq 'dish-ut', 'dish id');
ok($info->{hardware_version} eq 'hw1' && $info->{software_version} eq 'sw1',
    'dish versions');
ok($info->{country_code} eq 'US' && $info->{bootcount} == 7, 'dish country and boot');
ok($info->{alerts_bitfield} == $row->{alerts_bitfield}, 'dish info alerts');
ok($info->{last_seen_ts} == $now, 'dish info time');

my $ev = SLMON::StatusMap::outage_event($st->{doc}, $now);
ok($ev->{type} eq 'dish_outage' && $ev->{duration_s} == 5, 'outage event');
ok($ev->{details} eq 'cause=2 start_ns=9007199254740995',
    'timestamp keeps integer digits');

my $again = SLMON::json_decode(SLMON::json_encode($st->{doc}));
ok(sprintf('%s', $again->{status}{outage}{start_timestamp_ns}) eq '9007199254740995',
    'json keeps the timestamp');

my $hist = SLMON::DishWire::decode_reply(grpc_frame($history_pb));
ok($hist->{op} eq 'history', 'history op');
same($hist->{doc}, {
	current => 4,
	pop_ping_drop_rate => [0, 0, 1, 0.5],
	pop_ping_latency_ms => [10, 11, 12, 13],
	downlink_throughput_bps => [100, 100, 100, 100],
	uplink_throughput_bps => [50, 50, 50, 50],
	outages => [{
		cause => 3,
		start_timestamp_ns => 50,
		duration_ns => 1000000000,
		did_switch => T(),
	}],
}, 'history hash');
my @samples = SLMON::History::ring_samples($hist->{doc}, $now);
ok(@samples == 4, 'four history samples');
ok($samples[0]{counter} == 1 && $samples[0]{ts} == $now - 3, 'oldest sample');
ok($samples[2]{drop} == 1 && !defined $samples[2]{latency}, 'full drop clears latency');
ok($samples[3]{drop} == 0.5 && $samples[3]{latency} == 13, 'partial drop keeps latency');
ok($samples[0]{down_bps} == 100 && $samples[0]{up_bps} == 50, 'history throughput');

my $map = SLMON::DishWire::decode_reply(grpc_frame($map_pb));
ok($map->{op} eq 'map', 'map op');
same($map->{doc}, {
	num_rows => 2,
	num_cols => 2,
	snr => [-1, 1, 0, 1],
}, 'map hash');

my $empty = SLMON::DishWire::decode_reply(grpc_frame(pb('a27d00')));
ok(!defined $empty->{doc}{legacy_state}, 'empty legacy is null');
ok($empty->{doc}{status}{device_info}{id} eq '', 'empty id');
ok($empty->{doc}{status}{device_info}{bootcount} == 0, 'empty bootcount');
ok(!$empty->{doc}{status}{alerts}{motors_stuck}, 'empty alert is false');
ok(ref($empty->{doc}{status}{alerts}{motors_stuck}) eq 'JSON::PP::Boolean',
    'empty alert is a json bool');
ok($empty->{doc}{status}{pop_ping_drop_rate} == 0, 'empty drop is zero');
ok(!defined SLMON::StatusMap::outage_event($empty->{doc}, 1), 'no outage event');
my $empty_row = SLMON::StatusMap::status_row($empty->{doc}, 1);
ok(!defined $empty_row->{state}, 'empty legacy is not a state name');
ok($empty_row->{alerts_bitfield} == 0, 'no alert bits');

my $legacy = SLMON::DishWire::decode_reply(grpc_frame(pb('a27d03f03e01')));
ok($legacy->{doc}{legacy_state} == 1 && @{$legacy->{unknown}} == 0, 'legacy field 1006');
ok(SLMON::StatusMap::status_row($legacy->{doc}, 1)->{state} eq 'CONNECTED',
    'legacy 1 is CONNECTED');

my $unk = SLMON::DishWire::decode_reply(grpc_frame(pb('a27d03b83e01')));
ok(@{$unk->{unknown}} == 1 && @{$unk->{retyped}} == 0, 'one unknown field');
ok($unk->{unknown}[0]{message} eq 'DishGetStatusResponse'
    && $unk->{unknown}[0]{number} == 999
    && $unk->{unknown}[0]{wire} eq 'varint', 'unknown is field 999');
ok($unk->{doc}{status}{pop_ping_drop_rate} == 0, 'unknown value is not stored');

my $off = SLMON::DishWire::decode_reply(grpc_frame(pb('a27d050a0328901c')));
ok(@{$off->{unknown}} == 0, 'utc_offset_s is known');
ok(!exists $off->{doc}{status}{device_info}{utc_offset_s},
    'utc_offset_s is still not a key');

my $neg = SLMON::DishWire::decode_reply(grpc_frame(pb(
    'a27d0d0a0b28b0f3feffffffffffff01')));
ok(@{$neg->{unknown}} == 0 && @{$neg->{retyped}} == 0,
    'negative utc_offset_s is a known varint');
ok(!exists $neg->{doc}{status}{device_info}{utc_offset_s},
    'negative utc_offset_s is still not a key');
my ($wide, $wide_i) = SLMON::DishWire::_varint_at(
    pack('H*', 'ffffffffffffffffff01'), 0);
ok("$wide" eq '18446744073709551615' && $wide_i == 10,
    'negative one keeps the 64 unsigned bits');
dies(sub { SLMON::DishWire::_varint_at(pack('H*', 'ffffffffffffffffff7f'), 0) },
    qr/64-bit/, 'varint wider than 64 bits');

my $re = SLMON::DishWire::decode_reply(grpc_frame(pb('a27d03884201')));
ok(@{$re->{retyped}} == 1, 'one retyped field');
ok($re->{retyped}[0]{name} eq 'signal_quality'
    && $re->{retyped}[0]{number} == 1057
    && $re->{retyped}[0]{wire} eq 'varint'
    && $re->{retyped}[0]{expect} eq 'fixed32', 'signal_quality arrived as a varint');
ok($re->{doc}{status}{signal_quality} == 0, 'retyped value is not stored');

my $nan = SLMON::DishWire::decode_reply(grpc_frame(pb('a27d068d420000c07f')));
ok(!defined $nan->{doc}{status}{signal_quality}, 'nan signal is null');
ok($nan->{doc}{status}{pop_ping_latency_ms} == 0, 'other floats stay zero');
my $inf = SLMON::DishWire::decode_reply(grpc_frame(pb('a27d068d420000807f')));
ok(!defined $inf->{doc}{status}{signal_quality}, 'infinite signal is null');

my $frame = grpc_frame($status_pb);
my $part1 = substr($frame, 0, 3);
my $part2 = substr($frame, 3);
my $captured = http2_frame(4, 0, 0, '')
    . http2_frame(1, 0x4, 1, 'x')
    . http2_frame(0, 0, 1, $part1)
    . http2_frame(0, 0x9, 1, pack('C', 2) . $part2 . "\x00\x00");
my $joined = SLMON::DishWire::unwrap_http2($captured);
ok($joined eq $frame, 'http2 data is joined and unpadded');
same(SLMON::DishWire::decode_reply($joined)->{doc}, $status_exp,
    'captured reply decodes to the status hash');

dies(sub { SLMON::DishWire::unwrap_http2($preface . $captured) },
    qr/preface is not a reply/, 'preface is not a reply');
dies(sub { SLMON::DishWire::unwrap_http2(http2_frame(4, 0, 0, '')) },
    qr/no data/, 'settings without data');
dies(sub { SLMON::DishWire::decode_reply(pack('C N', 1, 0)) },
    qr/compressed/, 'compressed grpc is rejected');
dies(sub { SLMON::DishWire::decode_reply('abc') }, qr/short grpc/, 'short grpc frame');
dies(sub { SLMON::DishWire::decode_reply(pack('C N', 0, 0) . 'x') },
    qr/trailing/, 'trailing grpc bytes');
dies(sub { SLMON::DishWire::decode_reply(pack('C N', 0, 5) . 'x') },
    qr/truncated grpc/, 'truncated grpc message');
dies(sub { SLMON::DishWire::decode_reply(grpc_frame('')) },
    qr/no dish reply/, 'empty response');
dies(sub { SLMON::DishWire::decode_reply(grpc_frame(pb('a27d00b27d00'))) },
    qr/more than one/, 'two replies in one response');

sub hdrs {
	my ($block) = @_;
	return SLMON::DishWire::_hpack_decode(pack('H*', $block));
}

sub hdr_eq {
	my ($got, $exp, $name) = @_;
	my $good = @$got == @$exp;
	for my $i (0 .. $#$exp) {
		$good = 0 if $i > $#$got;
		next if $i > $#$got;
		$good = 0 if $got->[$i][0] ne $exp->[$i][0] || $got->[$i][1] ne $exp->[$i][1];
	}
	if (!$good) {
		print STDERR "header $_: $got->[$_][0] = $got->[$_][1]\n" for 0 .. $#$got;
	}
	ok($good, $name);
	return;
}

my $dyn = SLMON::DishWire::_hpack_new();
hdr_eq(SLMON::DishWire::_hpack_decode(pack('H*',
	'828684418cf1e3c2e5f23a6ba0ab90f4ff'), $dyn), [
	[':method', 'GET'],
	[':scheme', 'http'],
	[':path', '/'],
	[':authority', 'www.example.com'],
], 'hpack request with huffman');
hdr_eq(SLMON::DishWire::_hpack_decode(pack('H*',
	'828684be5886a8eb10649cbf'), $dyn), [
	[':method', 'GET'],
	[':scheme', 'http'],
	[':path', '/'],
	[':authority', 'www.example.com'],
	['cache-control', 'no-cache'],
], 'hpack dynamic index');
SLMON::DishWire::_hpack_decode(pack('C*', 0x20, 0x82), $dyn);
dies(sub { SLMON::DishWire::_hpack_decode(pack('C', 0xbe), $dyn) },
    qr/hpack index/, 'table size zero drops the dynamic index');

hdr_eq(hdrs('488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3'), [
	[':status', '302'],
	['cache-control', 'private'],
	['date', 'Mon, 21 Oct 2013 20:13:21 GMT'],
	['location', 'https://www.example.com'],
], 'hpack response with huffman');
ok(SLMON::DishWire::_huff_decode(pack('H*', '9bd9ab')) eq 'gzip', 'huffman gzip');
ok(SLMON::DishWire::_huff_decode(pack('H*',
	'94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007'))
    eq 'foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1',
    'huffman cookie');

dies(sub { SLMON::DishWire::call('127.0.0.1:9', 'reboot') },
    qr/unknown dish op/, 'call rejects an unknown op');
dies(sub { SLMON::DishWire::call('not a host', 'status') },
    qr/authority/, 'call authority');
dies(sub { SLMON::DishWire::call('192.168.100.1', 'status') },
    qr/host:port/, 'call target needs a port');

sub enc_varint {
	my ($n) = @_;
	my $out = '';
	while ($n >= 128) {
		$out .= pack('C', ($n & 0x7f) | 0x80);
		$n >>= 7;
	}
	$out .= pack('C', $n);
	return $out;
}

sub pb_varint {
	my ($num, $val) = @_;
	return enc_varint(($num << 3) | 0) . enc_varint($val);
}

sub pb_bytes {
	my ($num, $blob) = @_;
	return enc_varint(($num << 3) | 2) . enc_varint(length $blob) . $blob;
}

sub srv_fill {
	my ($sock, $buf, $need) = @_;
	while (length($$buf) < $need) {
		my $got = sysread($sock, my $chunk, 65536);
		die "server eof\n" if !defined $got || $got == 0;
		$$buf .= $chunk;
	}
	return;
}

sub srv_frame {
	my ($sock, $buf) = @_;
	srv_fill($sock, $buf, 9);
	my $head = substr($$buf, 0, 9, '');
	my $flen = unpack('N', "\0" . substr($head, 0, 3));
	my $type = ord(substr($head, 3, 1));
	my $flags = ord(substr($head, 4, 1));
	my $sid = unpack('N', substr($head, 5, 4)) & 0x7fffffff;
	die "server frame $flen\n" if $flen > 1048576;
	srv_fill($sock, $buf, $flen) if $flen;
	my $payload = $flen ? substr($$buf, 0, $flen, '') : '';
	return ($type, $flags, $sid, $payload);
}

sub srv_write {
	my ($sock, $bytes) = @_;
	my $off = 0;
	while ($off < length $bytes) {
		my $w = syswrite($sock, $bytes, length($bytes) - $off, $off);
		die "server write: $!\n" if !defined $w || $w == 0;
		$off += $w;
	}
	return;
}

sub srv_take_request {
	my ($cli, $need, $op) = @_;
	my $buf = '';
	my $magic = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
	srv_fill($cli, \$buf, length $magic);
	die "server preface\n" if substr($buf, 0, length($magic), '') ne $magic;
	my $conn = 65535;
	my $init = 65535;
	my $stream;
	my $got = 0;
	my $acked = 0;
	my $req = '';
	my $sent = 0;
	while (!$got || !$acked) {
		my ($type, $flags, $sid, $payload) = srv_frame($cli, \$buf);
		if ($type == 4 && !($flags & 1)) {
			die "server settings\n" if length($payload) % 6;
			for (my $i = 0; $i < length $payload; $i += 6) {
				my ($id, $val) = unpack('n N', substr($payload, $i, 6));
				if ($id == 4) {
					my $delta = $val - $init;
					$init = $val;
					$stream += $delta if defined $stream;
				}
			}
			if (!$sent) {
				srv_write($cli, http2_frame(4, 0, 0, ''));
				$sent = 1;
			}
		} elsif ($type == 4 && ($flags & 1)) {
			$acked = 1;
		} elsif ($type == 8) {
			die "server window\n" if length($payload) != 4;
			my $inc = unpack('N', $payload) & 0x7fffffff;
			die "server window zero\n" if $inc == 0;
			if ($sid == 0) {
				$conn += $inc;
			} elsif (defined $stream) {
				$stream += $inc;
			}
		} elsif ($type == 1) {
			$stream = $init if !defined $stream;
		} elsif ($type == 0) {
			$req .= $payload;
			$got = 1 if $flags & 1;
		}
	}
	die "server connection window $conn need $need\n" if $conn < $need;
	die "server stream window\n" if !defined $stream || $stream < $need;
	my $body = SLMON::DishWire::request_bytes($op);
	my $expect = pack('C N', 0, length $body) . $body;
	die "server request\n" if $req ne $expect;
	return;
}

sub srv_reply {
	my ($cli, $hdr, $data, $trailers) = @_;
	if (defined $trailers) {
		srv_write($cli, http2_frame(1, 0x4, 1, $hdr));
		my $off = 0;
		while ($off < length $data) {
			my $n = length($data) - $off;
			$n = 16384 if $n > 16384;
			srv_write($cli, http2_frame(0, 0, 1, substr($data, $off, $n)));
			$off += $n;
		}
		srv_write($cli, http2_frame(1, 0x5, 1, $trailers));
	} else {
		srv_write($cli, http2_frame(1, 0x5, 1, $hdr));
	}
	while (1) {
		my $got = sysread($cli, my $chunk, 65536);
		last if !defined $got || $got == 0;
	}
	close $cli;
	return;
}

sub with_server {
	my ($child, $op) = @_;
	my $srv = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		LocalPort => 0,
		Proto     => 'tcp',
		Listen    => 1,
		Reuse     => 1,
	) or die "listen: $!\n";
	my $port = $srv->sockport;
	my $pid = fork();
	die "fork: $!\n" if !defined $pid;
	if ($pid == 0) {
		$SIG{ALRM} = sub { die "loopback server hung\n" };
		$SIG{PIPE} = 'IGNORE';
		alarm(8);
		eval { $child->($srv); };
		my $err = $@;
		alarm(0);
		if ($err) {
			$err =~ s/[^\x20-\x7e]/./g;
			print STDERR "loopback server: $err\n";
			exit 1;
		}
		exit 0;
	}
	close $srv;
	my $got = eval { SLMON::DishWire::call("127.0.0.1:$port", $op) };
	my $err = $@;
	waitpid($pid, 0);
	return ($got, $err, $?);
}

my $rows = 100;
my $cols = 200;
my $floats = pack('f<*', (1) x ($rows * $cols));
my $inner = pb_varint(1, $rows) . pb_varint(2, $cols) . pb_bytes(3, $floats);
my $map_msg = pb_bytes(2008, $inner);
my $map_grpc = pack('C N', 0, length $map_msg) . $map_msg;
ok(length($map_grpc) > 65535, 'fixture map is larger than the default window');

my ($mapgot, $maperr, $maprc) = with_server(sub {
	my ($srv) = @_;
	my $cli = $srv->accept or die "accept: $!\n";
	binmode $cli;
	srv_take_request($cli, length $map_grpc, 'map');
	srv_reply($cli, pack('C', 0x88)
	    . SLMON::DishWire::_hpack_lit_name(31, 'application/grpc'),
	    $map_grpc, SLMON::DishWire::_hpack_lit_new('grpc-status', '0'));
}, 'map');
if ($maperr) {
	$maperr =~ s/[^\x20-\x7e]/./g;
	print STDERR "loopback client: $maperr\n";
}
ok(!$maperr && $maprc == 0 && $mapgot && $mapgot->{op} eq 'map'
    && $mapgot->{doc}{num_rows} == $rows
    && $mapgot->{doc}{num_cols} == $cols
    && @{$mapgot->{doc}{snr}} == $rows * $cols
    && $mapgot->{doc}{snr}[0] == 1
    && $mapgot->{doc}{snr}[-1] == 1
    && @{$mapgot->{unknown}} == 0 && @{$mapgot->{retyped}} == 0,
    'loopback map larger than the default window');

my ($bad, $baderr, $badrc) = with_server(sub {
	my ($srv) = @_;
	my $cli = $srv->accept or die "accept: $!\n";
	binmode $cli;
	srv_take_request($cli, 1, 'status');
	srv_reply($cli, pack('C', 0x88)
	    . SLMON::DishWire::_hpack_lit_name(31, 'application/grpc')
	    . SLMON::DishWire::_hpack_lit_new('grpc-status', '1')
	    . SLMON::DishWire::_hpack_lit_new('grpc-message', 'no'),
	    '', undef);
}, 'status');
ok(!$bad && $badrc == 0 && $baderr =~ /grpc status 1/,
    'grpc status is not a dish hash');

print "$n tests, $fail failed\n";
exit($fail ? 1 : 0);
