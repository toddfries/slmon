#!/usr/bin/perl

use strict;
use warnings;
use File::Path qw(remove_tree);
use FindBin;

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../blib";
use SLMON ();
use SLMON::Auth;
use SLMON::Config;
use SLMON::DB;
use MIME::Base64 qw(encode_base64);
use SLMON::Dash;
use SLMON::Top;
use SLMON::Http;
use SLMON::Parent;
use SLMON::StatusMap;
use SLMON::History;
use SLMON::Obstruction;
use SLMON::Watchdog;
use SLMON::Weather;

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

my $secret = SLMON::Auth::session_secret();
ok(length($secret) == 64, 'secret is 32 bytes of hex');
ok(SLMON::Auth::session_secret($secret) eq $secret, 'secret is not rotated');

eval { SLMON::Auth::hash_password('short') };
ok($@ && $@ =~ /8/, 'password under 8 characters is rejected');

my $hash = SLMON::Auth::hash_password('regress-secret');
ok($hash =~ /\A\$2b\$/, 'password stored as bcrypt 2b');
ok(SLMON::Auth::verify_password('regress-secret', $hash), 'bcrypt accepts the password');
ok(!SLMON::Auth::verify_password('regress-secret-x', $hash), 'bcrypt rejects a different password');

pipe(my $rd, my $wr) or die "pipe: $!";
eval { SLMON::Auth::prompt($rd, $wr) };
ok($@ && $@ =~ /no admin password is set/, 'non-tty init fails');
close $rd;
close $wr;

my $now = 1_700_000_000;
my $cookie = SLMON::Auth::sign_session('admin', $now + 10, $secret);
ok(SLMON::Auth::verify_session($cookie, $secret, $now) eq 'admin', 'cookie verifies');
my $tampered = $cookie;
my $last = substr($tampered, -1, 1);
substr($tampered, -1, 1) = $last eq '0' ? '1' : '0';
ok(!defined SLMON::Auth::verify_session($tampered, $secret, $now), 'tampered cookie rejected');
my $expired = SLMON::Auth::sign_session('admin', $now - 1, $secret);
ok(!defined SLMON::Auth::verify_session($expired, $secret, $now), 'expired cookie rejected');

my $rate = SLMON::Auth::rate_new();
my $blocked = 0;
$blocked = SLMON::Auth::rate_fail($rate, '10.0.0.1', 1000) for 1 .. 5;
ok($blocked, 'fifth failure in the window blocks');
ok(SLMON::Auth::rate_blocked($rate, '10.0.0.1', 1200), 'still blocked inside the window');
ok(!SLMON::Auth::rate_blocked($rate, '10.0.0.1', 1000 + 301), 'outside the window is not blocked');
SLMON::Auth::rate_success($rate, '10.1.1.1', 5000);
ok(!SLMON::Auth::rate_blocked($rate, '10.1.1.1', 5000), 'a success is not a block');

my @drop = (0) x 900;
my @lat = (10) x 900;
my @bps = (100) x 900;
my @up = (50) x 900;
my @samples = SLMON::History::ring_samples({
	current => 100,
	pop_ping_drop_rate => \@drop,
	pop_ping_latency_ms => \@lat,
	downlink_throughput_bps => \@bps,
	uplink_throughput_bps => \@up,
}, 5000);
ok(@samples == 100, 'non-wrap length');
ok($samples[0]{counter} == 1, 'non-wrap oldest counter');
ok($samples[-1]{counter} == 100, 'non-wrap newest counter');
ok($samples[0]{ts} == 5000 - 99, 'non-wrap oldest timestamp');

@samples = SLMON::History::ring_samples({
	current => 905,
	pop_ping_drop_rate => \@drop,
	pop_ping_latency_ms => \@lat,
	downlink_throughput_bps => \@bps,
	uplink_throughput_bps => \@up,
}, 9000);
ok(@samples == 900, 'wrap length');
ok($samples[0]{counter} == 6, 'wrap oldest counter');
ok($samples[-1]{counter} == 905, 'wrap newest counter');

@samples = SLMON::History::ring_samples({
	current => 3,
	pop_ping_drop_rate => [0, 1, 0.2],
	pop_ping_latency_ms => [5, 9, 8],
	downlink_throughput_bps => [1, 2, 3],
	uplink_throughput_bps => [1, 2, 3],
}, 100);
ok(!defined $samples[1]{latency}, 'drop rate >= 1 clears latency');
ok($samples[2]{latency} == 8, 'partial drop keeps latency');

my $cfg = SLMON::Config::parse('');
ok($cfg->{dish_interval_s} == 30, 'default dish interval');
eval { SLMON::Config::parse("dish_interval_s = 1\n") };
ok($@ && $@ =~ /at least 2/, 'dish interval cannot be under 2 seconds');
my $two = SLMON::Config::parse("dish_interval_s = 2\n");
ok($two->{dish_interval_s} == 2, 'dish interval of 2 seconds is accepted');
my $rev_a = SLMON::Http::page_rev($cfg);
my $rev_b = SLMON::Http::page_rev($two);
ok($rev_a =~ /\A[0-9a-f]{8}\z/ && $rev_b =~ /\A[0-9a-f]{8}\z/ && $rev_a ne $rev_b,
    'page revision changes with the dish interval');
ok($cfg->{dish_host} eq '192.168.100.1', 'default dish host');
ok($cfg->{rollup_interval_s} == 60, 'default rollup interval');
ok($cfg->{raw_retention_days} == 90, 'default raw retention');
ok($cfg->{log_level} eq 'info', 'default log level is info');
my $dbg = SLMON::Config::parse("log_level = debug\n");
ok($dbg->{log_level} eq 'debug', 'debug log level accepted');
eval { SLMON::Config::parse("log_level = trace\n") };
ok($@ && $@ =~ /log_level/, 'log level must be info or debug');
ok($cfg->{dish_client} eq 'perl', 'default dish client is perl');
my $xs = SLMON::Config::parse("dish_client = xs\n");
ok($xs->{dish_client} eq 'xs', 'xs dish client accepted');
eval { SLMON::Config::parse("dish_client = cpp\n") };
ok($@ && $@ =~ /dish_client/, 'dish client must be perl or xs');
eval { SLMON::Config::parse("nope = 1\n") };
ok($@ && $@ =~ /unknown config key/, 'unknown key rejected');
ok(@{ $cfg->{listens} } == 1 && $cfg->{listen} eq '127.0.0.1:8080',
    'default is one listen line');
my $multi = SLMON::Config::parse("listen = 127.0.0.1:8080\nlisten = [::1]:8080\n");
ok($multi->{listen} eq '127.0.0.1:8080'
    && $multi->{listens}[1] eq '[::1]:8080'
    && @{ $multi->{listens} } == 2,
    'a repeated listen line is kept');
my $plain6 = SLMON::Config::parse("listen = ::1:9090\n");
ok($plain6->{listen} eq '[::1]:9090', 'an ipv6 listen is bracketed');
eval { SLMON::Config::parse("listen = [::1]:80\n") };
ok($@ && $@ =~ /listen port/, 'an ipv6 port below 1024 is rejected');
SLMON::Config::apply_paths($multi, listen => '127.0.0.1:18080');
ok(@{ $multi->{listens} } == 1 && $multi->{listen} eq '127.0.0.1:18080',
    '-l replaces every listen line');
eval { SLMON::Config::parse("db = pg\n") };
ok($@ && $@ =~ /pg_db/, 'pg without pg_db rejected');
my $pg = SLMON::Config::parse("db = pg\npg_db = slmon\n");
ok($pg->{db} eq 'pg' && $pg->{pg_db} eq 'slmon', 'pg config accepted');

eval { SLMON::DB::normalize_query({ op => 'latest', table => 'settings' }) };
ok($@ && $@ =~ /unknown table/, 'unknown table refused');
my $q = SLMON::DB::normalize_query({ op => 'raw', table => 'metrics', limit => 999999 });
ok($q->{limit} == 50000, 'limit above 50000 clamped');
my $qd = SLMON::DB::normalize_query({ op => 'raw', table => 'history_samples' });
ok($qd->{limit} == 5000, 'default limit 5000');

my $dir = "/tmp/slmon-unit-$$";
mkdir $dir, 0700 or die "mkdir: $!";
END { remove_tree($dir) if $dir && -d $dir }

my $dbcfg = SLMON::Config::parse('');
SLMON::Config::apply_paths($dbcfg, db_path => "$dir/t.db", root => '/none');
my $dbh = SLMON::DB::open_db($dbcfg);
SLMON::DB::init_schema($dbh);

my @chunk;
for my $i (1 .. 30) {
	push @chunk, {
		counter => $i, ts => 1000 + $i,
		drop => ($i == 3 ? 1 : 0), latency => 15,
		down_bps => 8000, up_bps => 8,
	};
}
SLMON::DB::ingest_history($dbh, { bootcount => 1, samples => \@chunk });
my ($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
ok($count == 30, '30-sample chunk stored');
my ($lat3) = $dbh->selectrow_array(
    'SELECT ping_latency_ms FROM history_samples WHERE dish_counter = 3');
ok(!defined $lat3, 'drop rate 1 stores NULL latency');
SLMON::DB::ingest_history($dbh, { bootcount => 1, samples => [ $chunk[-1] ] });
($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
ok($count == 30, 'duplicate counter ignored');
SLMON::DB::ingest_history($dbh, {
	bootcount => 1,
	current   => 40,
	samples   => [ map { {
		counter => $_, ts => 1100 + $_, drop => 0, latency => 15,
		down_bps => 8000, up_bps => 8,
	} } (10 .. 20) ],
});
($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
ok($count == 30, 'old chunk with a forward tip is not a new run');
SLMON::DB::ingest_history($dbh, {
	bootcount => 1,
	current   => 40,
	samples   => [ map { {
		counter => $_, ts => 1000 + $_, drop => 0, latency => 15,
		down_bps => 8000, up_bps => 8,
	} } (20 .. 40) ],
});
($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
ok($count == 40, 'overlapping ring stores only the new counters');
my ($overlap_runs) = $dbh->selectrow_array(
    'SELECT COUNT(DISTINCT run_id) FROM history_samples');
ok($overlap_runs == 1, 'overlapping ring stays on the same run');
SLMON::DB::ingest_history($dbh, {
	bootcount => 1,
	samples => [{ counter => 1, ts => 2000, drop => 0, latency => 1, down_bps => 8, up_bps => 8 }],
});
my ($runs) = $dbh->selectrow_array('SELECT COUNT(DISTINCT run_id) FROM history_samples');
ok($runs == 2, 'counter moving backwards opens a run');
SLMON::DB::ingest_history($dbh, {
	bootcount => 9,
	samples => [{ counter => 80, ts => 3000, drop => 0, latency => 1, down_bps => 8, up_bps => 8 }],
});
($runs) = $dbh->selectrow_array('SELECT COUNT(DISTINCT run_id) FROM history_samples');
ok($runs == 3, 'bootcount change opens a run');

my $day = 1_700_000_000 - (1_700_000_000 % 86400);
my @minute;
for my $i (0 .. 59) {
	push @minute, {
		counter => 500 + $i, ts => $day + $i,
		drop => ($i == 0 ? 1 : 0), latency => 40,
		down_bps => 8000, up_bps => 1000,
	};
}
SLMON::Rollup::roll_minutes($dbh, $day + 60);
SLMON::DB::ingest_history($dbh, { bootcount => 9, samples => \@minute });
SLMON::Rollup::roll_minutes($dbh, $day + 60);
my $minrow = $dbh->selectrow_hashref(
    'SELECT * FROM metrics_minutely WHERE ts_minute = ?', undef, $day);
ok($minrow && $minrow->{sample_count} == 60, 'one minutely row');
ok($minrow && $minrow->{down_bytes} == 60000, 'minutely bytes are sum(bps)/8');
ok($minrow && abs($minrow->{avg_ping_latency_ms} - 40) < 0.001, 'null latency skipped in average');
ok($minrow && defined $minrow->{jitter_ms} && abs($minrow->{jitter_ms}) < 0.001,
    'flat minute jitter is zero');
ok($minrow && !defined $minrow->{avg_obstr_fraction},
    'minute obstruction stays null without status polls');
SLMON::Rollup::roll_hours($dbh, $day + 3600);
my ($hbytes) = $dbh->selectrow_array(
    'SELECT down_bytes FROM metrics_hourly WHERE ts_hour = ?', undef, $day);
ok(defined $hbytes && $hbytes == 60000, 'hourly rollup');
SLMON::Rollup::roll_days($dbh, $day + 86400);
my ($dbytes) = $dbh->selectrow_array(
    'SELECT down_bytes FROM metrics_daily WHERE ts_day = ?', undef, $day);
ok(defined $dbytes && $dbytes == 60000, 'daily rollup');

SLMON::DB::insert_metric($dbh, {
	ts => $day + 10, obstr_fraction => 0.002,
	ping_drop_rate => 0, alerts_bitfield => 0,
});
SLMON::DB::insert_metric($dbh, {
	ts => $day + 40, obstr_fraction => 0.008,
	ping_drop_rate => 0, alerts_bitfield => 0,
});
SLMON::Rollup::roll_minutes($dbh, $day + 60);
$minrow = $dbh->selectrow_hashref(
    'SELECT * FROM metrics_minutely WHERE ts_minute = ?', undef, $day);
ok($minrow && abs($minrow->{avg_obstr_fraction} - 0.005) < 1e-9,
    'minute obstruction is the average of status polls');
ok($minrow && abs($minrow->{max_obstr_fraction} - 0.008) < 1e-9,
    'minute obstruction max is the highest status poll');
my @spread;
for my $i (0 .. 59) {
	push @spread, {
		counter => 800 + $i, ts => $day + 120 + $i,
		drop => 0, latency => ($i < 30 ? 10 : 30),
		down_bps => 8000, up_bps => 1000,
	};
}
SLMON::DB::ingest_history($dbh, { bootcount => 9, samples => \@spread });
SLMON::DB::insert_metric($dbh, {
	ts => $day + 130, obstr_fraction => 0.02,
	ping_drop_rate => 0, alerts_bitfield => 0,
});
SLMON::Rollup::roll_minutes($dbh, $day + 240);
my $m2 = $dbh->selectrow_hashref(
    'SELECT * FROM metrics_minutely WHERE ts_minute = ?', undef, $day + 120);
ok($m2 && abs($m2->{jitter_ms} - 20) < 0.001,
    'minute jitter is max latency minus min');
SLMON::Rollup::roll_hours($dbh, $day + 3600);
my $hour = $dbh->selectrow_hashref(
    'SELECT * FROM metrics_hourly WHERE ts_hour = ?', undef, $day);
ok($hour && abs($hour->{jitter_ms} - 30) < 0.001,
    'hourly jitter is the spread across the hour');
ok($hour && abs($hour->{max_obstr_fraction} - 0.02) < 1e-9,
    'hourly obstruction max is the highest minute');
ok($hour && abs($hour->{avg_obstr_fraction} - 0.0125) < 1e-9,
    'hourly obstruction averages the minute averages');
SLMON::Rollup::roll_days($dbh, $day + 86400);
my $dayrow = $dbh->selectrow_hashref(
    'SELECT * FROM metrics_daily WHERE ts_day = ?', undef, $day);
ok($dayrow && abs($dayrow->{jitter_ms} - 30) < 0.001,
    'daily jitter keeps the spread');
ok($dayrow && abs($dayrow->{max_obstr_fraction} - 0.02) < 1e-9,
    'daily obstruction max keeps the hour max');

my $gap = $day + 3600;
$dbh->do(
    'INSERT INTO metrics_minutely (ts_minute, sample_count, down_bytes, up_bytes) VALUES (?,?,?,?)',
    undef, $gap, 1, 1, 1);
SLMON::DB::ingest_history($dbh, {
	bootcount => 9,
	samples => [
		{ counter => 9000, ts => $gap + 1, drop => 0, latency => 5, down_bps => 8, up_bps => 8 },
		{ counter => 9001, ts => $gap + 2, drop => 0, latency => 17, down_bps => 8, up_bps => 8 },
	],
});
SLMON::DB::insert_metric($dbh, {
	ts => $gap + 3, obstr_fraction => 0.4,
	ping_drop_rate => 0, alerts_bitfield => 0,
});
$dbh->do(
    'INSERT INTO metrics_hourly (ts_hour, sample_count, down_bytes, up_bytes) VALUES (?,?,?,?)',
    undef, $gap, 1, 1, 1);
SLMON::Rollup::fill_gaps($dbh);
my $g = $dbh->selectrow_hashref(
    'SELECT * FROM metrics_minutely WHERE ts_minute = ?', undef, $gap);
ok($g && abs($g->{jitter_ms} - 12) < 0.001
    && abs($g->{avg_obstr_fraction} - 0.4) < 1e-9,
    'a stored minute picks up obstruction and jitter still on hand');
my $hg = $dbh->selectrow_hashref(
    'SELECT * FROM metrics_hourly WHERE ts_hour = ?', undef, $gap);
ok($hg && abs($hg->{jitter_ms} - 12) < 0.001
    && abs($hg->{max_obstr_fraction} - 0.4) < 1e-9
    && $hg->{down_bytes} == 1,
    'a stored hour fills obstruction and jitter without replacing bytes');

my $clock = 1_800_000_000;
my $raw_cut = $clock - 90 * 86400;
my $hour_cut = $clock - 365 * 86400;
my $min_cut = $clock - 730 * 86400;
SLMON::DB::ingest_history($dbh, {
	bootcount => 9,
	samples => [
		{ counter => 900, ts => $raw_cut - 1, drop => 0, latency => 1, down_bps => 8000, up_bps => 8 },
		{ counter => 901, ts => $raw_cut + 1, drop => 0, latency => 1, down_bps => 8000, up_bps => 8 },
	],
});
SLMON::DB::insert_metric($dbh, {
	ts => $raw_cut - 1, ping_drop_rate => 0, alerts_bitfield => 0,
	obstr_fraction => 0.25,
});
SLMON::DB::insert_metric($dbh, { ts => $raw_cut + 1, ping_drop_rate => 0, alerts_bitfield => 0 });
$dbh->do('INSERT INTO metrics_hourly (ts_hour, down_bytes, up_bytes, sample_count) VALUES (?,?,?,?)',
    undef, $hour_cut - 1, 5, 1, 1);
$dbh->do('INSERT INTO metrics_hourly (ts_hour, down_bytes, up_bytes, sample_count) VALUES (?,?,?,?)',
    undef, $hour_cut + 3600, 6, 1, 1);
$dbh->do('INSERT INTO metrics_minutely (ts_minute, down_bytes, up_bytes, sample_count) VALUES (?,?,?,?)',
    undef, $min_cut - 1, 7, 1, 1);
$dbh->do('INSERT INTO metrics_minutely (ts_minute, down_bytes, up_bytes, sample_count) VALUES (?,?,?,?)',
    undef, $min_cut + 60, 8, 1, 1);
SLMON::Rollup::retain($dbh, $clock, 90, 365, 730);
my ($old_hist) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM history_samples WHERE ts < ?', undef, $raw_cut);
my ($new_hist) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM history_samples WHERE ts = ?', undef, $raw_cut + 1);
ok($old_hist == 0, 'raw row older than the window is gone');
ok($new_hist == 1, 'raw row newer than the window stays');
my $old_hour = int(($raw_cut - 1) / 3600) * 3600;
my ($comp) = $dbh->selectrow_array(
    'SELECT down_bytes FROM metrics_hourly WHERE ts_hour = ?', undef, $old_hour);
ok(defined $comp && $comp == 1000, 'old raw row compressed into hourly');
my ($comp_ob, $comp_j) = $dbh->selectrow_array(
    'SELECT avg_obstr_fraction, jitter_ms FROM metrics_hourly WHERE ts_hour = ?',
    undef, $old_hour);
ok(defined $comp_ob && abs($comp_ob - 0.25) < 1e-9
    && defined $comp_j && abs($comp_j) < 1e-9,
    'compression keeps obstruction and jitter');
my ($old_metric) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM metrics WHERE ts < ?', undef, $raw_cut);
my ($new_metric) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM metrics WHERE ts = ?', undef, $raw_cut + 1);
ok($old_metric == 0 && $new_metric == 1, 'metrics follow the raw window');
my ($gone_hour) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM metrics_hourly WHERE ts_hour = ?', undef, $hour_cut - 1);
my ($stay_hour) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM metrics_hourly WHERE ts_hour = ?', undef, $hour_cut + 3600);
ok($gone_hour == 0 && $stay_hour == 1, 'hourly older than 365 days is rolled onward');
my $old_day = int(($hour_cut - 1) / 86400) * 86400;
my ($daily) = $dbh->selectrow_array(
    'SELECT down_bytes FROM metrics_daily WHERE ts_day = ?', undef, $old_day);
ok(defined $daily && $daily == 5, 'hourly row landed in daily');
my ($gone_min) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM metrics_minutely WHERE ts_minute = ?', undef, $min_cut - 1);
my ($stay_min) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM metrics_minutely WHERE ts_minute = ?', undef, $min_cut + 60);
ok($gone_min == 0 && $stay_min == 1, 'minutely older than 730 days is deleted');

my $obs = {};
ok(!defined SLMON::Obstruction::observe($obs, 0.2, 1), 'one high fraction does not log');
my $obev = SLMON::Obstruction::observe($obs, 0.2, 2);
ok($obev && $obev->{type} eq 'obstruction', 'second consecutive snapshot logs');
my $obs2 = {};
SLMON::Obstruction::observe($obs2, 0.9, 1);
ok(!defined SLMON::Obstruction::observe($obs2, 0, 2), 'a clear sample resets the streak');

my $wcfg = { disconnect_failures => 3, spike_ms => 200, spike_min_s => 30 };
my $wst = SLMON::Watchdog::state();
my @wev;
push @wev, SLMON::Watchdog::step($wst, { ok => 0 }, $_, $wcfg) for (0, 10, 20);
my @down = grep { $_->{type} eq 'disconnect' && !defined $_->{duration_s} } @wev;
ok(@down == 1, 'three failures confirm a disconnect');
my @recovered = SLMON::Watchdog::step($wst, { ok => 1, rtt_ms => 12 }, 50, $wcfg);
ok(@recovered == 1 && defined $recovered[0]{duration_s} && $recovered[0]{duration_s} == 30,
    'the next success records duration');
my $sst = SLMON::Watchdog::state();
SLMON::Watchdog::step($sst, { ok => 1, rtt_ms => 400 }, 0, $wcfg);
my @spike = SLMON::Watchdog::step($sst, { ok => 1, rtt_ms => 10 }, 20, $wcfg);
my $spiked = grep { $_->{type} eq 'latency_spike' } @spike;
ok(!$spiked, 'a spike under 30s does not log');

ok(SLMON::Weather::warning(wmo_code => 95, wind_kmh => 1) =~ /thunderstorm/, 'thunderstorm');
ok(SLMON::Weather::warning(wmo_code => 75, wind_kmh => 1) =~ /heavy snow/, 'heavy snow');
ok(SLMON::Weather::warning(wmo_code => 0, wind_kmh => 50) =~ /high wind/, 'high wind');
ok(!defined SLMON::Weather::warning(wmo_code => 0, wind_kmh => 10), 'clear sample');

sub http_req {
	my ($method, $path, %opt) = @_;
	return {
		method  => $method,
		path    => $path,
		query   => $opt{query} || {},
		headers => $opt{headers} || {},
		body    => $opt{body} // '',
	};
}

my $hctx = {
	secret => $secret,
	admin  => 'admin',
	rate   => SLMON::Auth::rate_new(),
	ip     => '127.0.0.1',
	now    => time,
};
my $form = SLMON::Http::respond(http_req('GET', '/login'), $hctx);
ok($form =~ m{\AHTTP/1.0 200 } && $form =~ m{text/html}
    && $form =~ m{action="/login"} && $form =~ m{name="password"},
    'login form');
ok($form =~ /setInterval\(check, 2000\)/ && $form !~ /id="live"/
    && $form =~ /name="slmon-rev"/
    && $form =~ /rel="manifest" href="\/manifest.webmanifest"/
    && $form =~ /id="install" hidden/
    && $form =~ /serviceWorker.register\('\/sw.js'\)/
    && $form =~ /beforeinstallprompt/,
    'login page checks for a newer revision');
my $root = SLMON::Http::respond(http_req('GET', '/'), $hctx);
ok($root =~ m{\AHTTP/1.0 303 } && $root =~ m{Location: /login},
    'root sends a browser to the login form');
my $tok = SLMON::Auth::sign_session('admin', time + 3600, $secret);
my $home = SLMON::Http::respond(http_req('GET', '/',
    headers => { cookie => "slmon_session=$tok" },
    query => { range => '6h' }), {
	%$hctx,
	dash => sub {
		return {
			series => [{
				ts => 1_000, downlink_bps => 1_000_000,
				uplink_bps => 100_000, ping_latency_ms => 20,
				ping_drop_rate => 0.01, obstr_fraction => 0.002,
				down_bytes => 2_000_000_000, up_bytes => undef,
			}, {
				ts => 2_000, downlink_bps => 8_000_000,
				uplink_bps => 400_000, ping_latency_ms => 40,
				ping_drop_rate => 0, obstr_fraction => 0.004,
				jitter_ms => 12,
				down_bytes => undef, up_bytes => 2_000_000_000,
			}],
			latest => {
				ts => 2_000, downlink_bps => 8_000_000,
				uplink_bps => 200_000, ping_latency_ms => 18,
				ping_drop_rate => 0, obstr_fraction => 0.001,
				uptime_s => 3600, direction_azimuth => -19.6,
				direction_elevation => 68.5, snr => 1, gps_sats => 12,
				alerts_bitfield => 2,
			},
			info => {
				hardware_version => 'rev4',
				software_version => '2026.09',
				bootcount => 3,
				device_id => 'a<b',
			},
			events => [{ ts => 1500, type => 'ping_ok', details => 'rtt_ms=1' }],
			window_from => 0,
			window_to => 3000,
		};
	},
    });
ok($home =~ /Signed in as admin/ && $home =~ m{action="/logout"}
    && $home =~ /8\.0 Mbit\/s/
    && $home =~ m{<a href="/\?range=24h" aria-current="page">24 hours</a>}
    && $home =~ m{href="/export.csv\?range=24h"}
    && $home =~ m{href="/\?range=7d"} && $home =~ m{href="/\?range=30d"}
    && $home =~ m{href="/\?range=365d"} && $home =~ m{href="/\?range=ever">Ever</a>}
    && $home !~ /range=1h/ && $home !~ /range=6h/
    && $home =~ /id="overview".*id="quality".*id="throughput".*id="dish".*id="history"/s
    && $home =~ /id="quality".*<h2>Packet loss.*<h2>Latency.*<h2>Jitter.*<h2>Obstruction.*id="throughput"/s
    && $home =~ /id="throughput".*Bytes down.*2\.0 GB.*Bytes up.*2\.0 GB.*Bytes total.*4\.0 GB.*<h2>Downlink.*<h2>Uplink.*id="dish"/s
    && $home =~ /id="dish".*a&lt;b.*motors_stuck.*id="history"/s
    && $home !~ /id="overview".*motors_stuck.*id="quality"/s
    && $home !~ /a<b/ && $home =~ /No obstruction map stored/
    && $home =~ /class="series"/,
    'dashboard charts the stored samples');
ok($home =~ /id="live" data-drawn="/
    && $home =~ /name="slmon-refresh" content="30"/
    && $home =~ /Charts update every 30s/
    && $home =~ /sample every 30s/
    && $home =~ /setInterval\(check, 2000\)/
    && index($home, 'id="install"') > 0
    && index($home, 'id="install"') < index($home, 'id="live"')
    && $home =~ /j\.rev && rev && j\.rev !== rev/
    && $home =~ /Obstruction map every 5 min/
    && $home =~ /Listen 127\.0\.0\.1:8080/
    && $home =~ /Database sqlite/
    && $home =~ /raw 90 days/
    && $home =~ /id="sla"/
    && $home =~ />100%</
    && $home =~ /A ping sample is not an outage/,
    'dashboard shows config and redraws on the dish interval');
my $fast_view = SLMON::Dash::view_from({
    dish_interval_s => 4,
    dish_host => '10.0.0.1:9201',
    listen => '127.0.0.1:9',
    db => 'pg',
    raw_retention_days => 7,
    minutely_retention_days => 8,
    hourly_rollup_days => 9,
});
ok($fast_view->{chart_s} == 4 && $fast_view->{dish_port} == 9201, 'view follows config');
ok(SLMON::Dash::view_from({ dish_interval_s => 1 })->{chart_s} == 2,
    'chart interval stays at least 2s');
my $fast_html = SLMON::Dash::page({
    user => 'admin', view => $fast_view, rev => 'abcd1234', now => 100,
});
ok($fast_html =~ /sample every 4s/ && $fast_html =~ /Charts update every 4s/
    && $fast_html =~ /10\.0\.0\.1:9201/
    && $fast_html =~ /Listen 127\.0\.0\.1:9/
    && $fast_html =~ /Database pg/ && $fast_html =~ /raw 7 days/
    && $fast_html =~ /name="slmon-rev" content="abcd1234"/
    && $fast_html =~ /name="slmon-refresh" content="4"/
    && $fast_html =~ /setInterval\(advance, every \* 1000\)/,
    'dashboard states a shorter dish interval');
my $js = SLMON::Dash::live_script();
ok($js =~ m{\A<script>} && $js =~ m{</script>\z} && $js !~ m{</script>.+</script>}s,
    'the page script is one element');
my $health = SLMON::Http::respond(http_req('GET', '/health'), { %$hctx, rev => 'abc' });
ok($health =~ m{\AHTTP/1.0 200 } && $health =~ /Cache-Control: no-store/
    && $health =~ /"ok":true/ && $health =~ /"rev":"abc"/,
    'health reports the page revision');
my $manifest = SLMON::Http::respond(http_req('GET', '/manifest.webmanifest'), $hctx);
ok($manifest =~ m{\AHTTP/1.0 200 } && $manifest =~ m{application/manifest\+json}
    && $manifest =~ /Cache-Control: no-store/
    && $manifest =~ /"name":"slmon"/ && $manifest =~ /"start_url":"\/"/
    && $manifest =~ /"display":"standalone"/
    && $manifest =~ /"sizes":"192x192"/ && $manifest =~ /"sizes":"512x512"/,
    'manifest is installable without a session');
my $sw = SLMON::Http::respond(http_req('GET', '/sw.js'), $hctx);
ok($sw =~ m{\AHTTP/1.0 200 } && $sw =~ m{text/javascript}
    && $sw =~ /addEventListener\('fetch'/
    && $sw =~ /respondWith\(fetch\(event\.request\)\)/
    && $sw !~ /caches/,
    'worker fetches from the network and does not cache');
my $icon = SLMON::Http::respond(http_req('GET', '/icon-192.png'), $hctx);
my ($ibody) = $icon =~ /\r\n\r\n(.*)\z/s;
ok($icon =~ m{\AHTTP/1.0 200 } && $icon =~ m{image/png}
    && defined $ibody && substr($ibody, 0, 8) eq "\x89PNG\r\n\x1a\n"
    && unpack('N', substr($ibody, 16, 4)) == 192
    && unpack('N', substr($ibody, 20, 4)) == 192
    && $ibody =~ /\xff\xff\xff/s,
    '192 icon is a png with a light trace');
my $icon5 = SLMON::Dash::icon_png(512);
ok(substr($icon5, -12) eq pack('N', 0) . 'IEND' . pack('N', 0xAE426082)
    && unpack('N', substr($icon5, 16, 4)) == 512,
    '512 icon ends with a valid IEND chunk');
my $again = SLMON::Http::respond(http_req('GET', '/login',
    headers => { cookie => "slmon_session=$tok" }), $hctx);
ok($again =~ m{\AHTTP/1.0 303 } && $again =~ m{Location: /},
    'login form redirects when already signed in');
my $out = SLMON::Http::respond(http_req('POST', '/logout'), $hctx);
ok($out =~ m{\AHTTP/1.0 303 } && $out =~ m{Location: /login}
    && $out =~ /Max-Age=0/,
    'logout clears the cookie');
my $csv_denied = SLMON::Http::respond(http_req('GET', '/export.csv',
    query => { range => '24h' }), $hctx);
ok($csv_denied =~ m{\AHTTP/1.0 303 } && $csv_denied =~ m{Location: /login}
    && $csv_denied !~ /down_bytes/,
    'csv without a session redirects to login');
my $csv_bad = SLMON::Http::respond(http_req('GET', '/export.csv',
    headers => { cookie => 'slmon_session=not-a-cookie' }), $hctx);
ok($csv_bad =~ m{\AHTTP/1.0 303 } && $csv_bad =~ m{Location: /login},
    'csv with a bad cookie redirects to login');
my $csv_ok = SLMON::Http::respond(http_req('GET', '/export.csv',
    headers => { cookie => "slmon_session=$tok" },
    query => { range => '6h' }), {
	%$hctx,
	dash => sub {
		return {
			series => [
				{ ts_minute => 2000, down_bytes => undef, up_bytes => 1,
				    sample_count => 1 },
				{ ts_minute => 1000, down_bytes => 10, up_bytes => 4,
				    avg_downlink_bps => 8, sample_count => 1 },
			],
		};
	},
    });
my ($csv_body) = $csv_ok =~ /\r\n\r\n(.*)\z/s;
ok($csv_ok =~ m{\AHTTP/1.0 200 } && $csv_ok =~ m{text/csv}
    && $csv_ok =~ /filename="slmon-24h.csv"/
    && $csv_ok =~ /Cache-Control: no-store/
    && defined $csv_body
    && $csv_body =~ /\Ats,down_bytes,up_bytes,/
    && $csv_body =~ /^1000,10,4,8,/m
    && $csv_body =~ /^2000,,1,/m,
    'csv is the signed-in window and an unknown range is 24h');
my $csv_err = SLMON::Http::respond(http_req('GET', '/export.csv',
    headers => { cookie => "slmon_session=$tok" }), {
	%$hctx,
	dash => sub { die "db closed\n" },
    });
ok($csv_err =~ m{\AHTTP/1.0 500 } && $csv_err =~ /did not answer/
    && $csv_err !~ /db closed/,
    'csv hides a database failure');
my $ugly = SLMON::Auth::sign_session('a<b"c', time + 3600, $secret);
my $escaped = SLMON::Http::respond(http_req('GET', '/',
    headers => { cookie => "slmon_session=$ugly" }), {
	%$hctx,
	admin => 'a<b"c',
    });
ok($escaped =~ /a&lt;b&quot;c/ && $escaped !~ /a<b"c/,
    'home escapes the signed-in name');
my $limited_rate = SLMON::Auth::rate_new();
SLMON::Auth::rate_fail($limited_rate, '10.9.9.9', $hctx->{now}) for 1 .. 5;
my $limited = eval {
	SLMON::Http::respond(http_req('POST', '/login',
	    headers => { 'content-type' => 'application/x-www-form-urlencoded' },
	    body => 'user=a<b&password=secret'), {
		%$hctx,
		rate => $limited_rate,
		ip   => '10.9.9.9',
	});
};
ok($limited && $limited =~ m{\AHTTP/1.0 429 } && $limited =~ /Too many attempts/
    && $limited =~ /value="a&lt;b"/ && $limited !~ /value="a<b"/,
    'login form rate limit escapes the user field');

my $svg = SLMON::Dash::chart_svg(
	title => 'Downlink', unit => 'Mbit/s', from => 0, to => 100,
	points => [ { t => 0, v => 0 }, { t => 100, v => 8 } ],
);
my ($pts) = $svg =~ /class="series" points="([^"]+)"/;
my @ys = map { (split /,/, $_)[1] } split / /, ($pts // '');
ok(@ys == 2 && $ys[0] > $ys[1], 'a higher sample sits higher on the chart');
my $empty = SLMON::Dash::chart_svg(title => 'Downlink', from => 0, to => 10, points => []);
ok($empty =~ /No samples in this window/, 'an empty window says so');
my $raw = pack('f<*', -1, 1, 0, 1);
my $map = SLMON::Dash::map_svg({
	num_rows => 2, num_cols => 2, snr_b64 => MIME::Base64::encode_base64($raw, ''),
});
ok($map =~ /class="u"/ && $map =~ /class="c"/ && $map =~ /class="o"/
    && $map !~ /class="bore"/,
    'obstruction map marks unmeasured, clear, and blocked cells');
my $zenith = SLMON::Dash::map_svg({
	num_rows => 2, num_cols => 2, snr_b64 => MIME::Base64::encode_base64($raw, ''),
}, { az => 0, el => 90 });
ok($zenith =~ /class="bore" cx="8.0" cy="8.0"/,
    'zenith boresight is the center of the grid');
my $north = SLMON::Dash::map_svg({
	num_rows => 2, num_cols => 2, snr_b64 => MIME::Base64::encode_base64($raw, ''),
}, { az => 0, el => 0 });
ok($north =~ /class="bore" cx="8.0" cy="0.0"/,
    'north horizon is the top edge of the grid');
my $cal = SLMON::Dash::calendar_svg([
	{ ts => 100, type => 'ping_ok' },
	{ ts => 150, duration_s => 10, type => 'disconnect' },
], 0, 200);
ok($cal =~ /class="outage"/ && $cal =~ /disconnect/ && $cal !~ /ping_ok/,
    'calendar draws an outage and skips ping_ok');
my $quiet = SLMON::Dash::calendar_svg([
	{ ts => 10, type => 'ping_ok' },
], 0, 100);
ok($quiet =~ /No outages in this window/,
    'a window of only ping_ok has no outage mark');
my $sky = SLMON::Dash::page({
	user => 'ops',
	now => 1000,
	range => '24h',
	latest => { direction_azimuth => 0, direction_elevation => 90, ts => 1000 },
	map => { num_rows => 2, num_cols => 2, snr_b64 => MIME::Base64::encode_base64($raw, '') },
	events => [ { ts => 900, duration_s => 5, type => 'disconnect' } ],
});
ok($sky =~ /id="dish"/ && $sky =~ /class="bore" cx="8.0" cy="8.0"/
    && $sky =~ /The ring is the boresight/
    && $sky =~ /id="history"/ && $sky =~ /class="outage"/,
    'the page shows the boresight and the outage calendar');
my $beh = SLMON::Dash::page({
	user => 'ops',
	now => 1000,
	range => '24h',
	latest => {
		ts => 1000,
		obstr_fraction => 0.125,
		currently_obstructed => 1,
		obstruction_duration => 8,
		obstruction_interval => 90,
	},
});
ok($beh =~ /id="dish"/
    && $beh =~ /Fraction<\/span><b>12\.500%/
    && $beh =~ /Currently obstructed<\/span><b>yes</
    && $beh =~ /Prolonged duration<\/span><b>8s</
    && $beh =~ /Prolonged interval<\/span><b>1m 30s</,
    'dish shows the latest obstruction beside the fraction');
my $clear = SLMON::Dash::page({
	user => 'ops',
	now => 1000,
	range => '24h',
	latest => { ts => 1000, obstr_fraction => 0, currently_obstructed => 0 },
});
ok($clear =~ /id="dish"/
    && $clear =~ /Fraction<\/span><b>0\.000%/
    && $clear =~ /Currently obstructed<\/span><b>no</
    && $clear =~ /Prolonged duration<\/span><b>n\/a</
    && $clear =~ /Prolonged interval<\/span><b>n\/a</,
    'a clear dish shows zero fraction and no prolonged sample');
ok($sky !~ /id="weather"/ && $sky !~ /class="warn"/,
    'the page skips weather when no coordinates are configured');
ok(!SLMON::Dash::weather_on({})
    && !SLMON::Dash::weather_on({ latitude => '32.1' })
    && !SLMON::Dash::weather_on({ longitude => '-97.1' })
    && SLMON::Dash::weather_on({ latitude => '32.1', longitude => '-97.1' }),
    'weather loads only when both coordinates are set');
my $storm = SLMON::Dash::page({
	user => 'ops',
	now => 100,
	range => '24h',
	window_from => 0,
	window_to => 100,
	series => [ { ts => 20, ping_latency_ms => 30 } ],
	weather => [
		{ ts => 10, warning => 'thunderstorm' },
		{ ts => 40 },
	],
});
ok($storm =~ /id="weather"/
    && $storm =~ /Storm<\/span><b>1</
    && $storm =~ /Normal<\/span><b>1</
    && $storm =~ /Latest<\/span><b>normal</
    && $storm =~ /class="warn" x="123\.0" y="16\.0" width="195\.0"/
    && $storm =~ /<title>thunderstorm<\/title>/
    && $storm !~ /latitude=/,
    'a configured storm shades the latency chart');
my $quiet_wx = SLMON::Dash::page({
	user => 'ops',
	now => 100,
	range => '24h',
	window_from => 0,
	window_to => 100,
	series => [ { ts => 20, ping_latency_ms => 30 } ],
	weather => [],
});
ok($quiet_wx =~ /id="weather"/
    && $quiet_wx =~ /Storm<\/span><b>0</
    && $quiet_wx =~ /Latest<\/span><b>n\/a</
    && $quiet_wx !~ /class="warn"/,
    'configured weather with no rows draws an empty card');
ok(join(' ', SLMON::StatusMap::alert_names(2)) eq 'motors_stuck',
    'alert bits decode to names');
ok(SLMON::Dash::range_name('6h') eq '24h'
    && SLMON::Dash::range_name('1h') eq '24h'
    && SLMON::Dash::range_name('ever') eq 'ever'
    && SLMON::Dash::range_name('30d') eq '30d',
    'unknown windows fall back to 24 hours');
ok(!defined SLMON::Dash::range_seconds('ever')
    && SLMON::Dash::range_seconds('24h') == 86400
    && SLMON::Dash::range_seconds('7d') == 7 * 86400
    && SLMON::Dash::range_seconds('30d') == 30 * 86400
    && SLMON::Dash::range_seconds('365d') == 365 * 86400,
    'ever has no lower bound');
ok(SLMON::Dash::series_table('1h') eq 'metrics_minutely'
    && SLMON::Dash::series_table('24h') eq 'metrics_minutely'
    && SLMON::Dash::series_table('7d') eq 'metrics_hourly'
    && SLMON::Dash::series_table('30d') eq 'metrics_hourly'
    && SLMON::Dash::series_table('365d') eq 'metrics_daily'
    && SLMON::Dash::series_table('ever') eq 'metrics_daily',
    'chart window picks the rollup table');
ok(SLMON::Dash::hourly_tail('365d') && SLMON::Dash::hourly_tail('ever')
    && !SLMON::Dash::hourly_tail('30d') && !SLMON::Dash::hourly_tail('24h')
    && !SLMON::Dash::hourly_tail('1h'),
    'a year and ever keep the unrolled hours');
my $merged = SLMON::Dash::merge_unrolled(
    [{ ts_day => 86400, avg_downlink_bps => 1 }],
    [
	{ ts_hour => 3600, avg_downlink_bps => 2 },
	{ ts_hour => 86400 + 3600, avg_downlink_bps => 3 },
	{ ts_hour => 2 * 86400, avg_downlink_bps => 4 },
    ],
);
ok(@$merged == 3
    && $merged->[0]{ts_day} == 86400
    && $merged->[1]{ts_hour} == 3600
    && $merged->[2]{ts_hour} == 2 * 86400,
    'hourly rows fill days that have no daily row');
my $vol = SLMON::Dash::volume_bytes([
    { down_bytes => 1000, up_bytes => undef },
    { down_bytes => undef, up_bytes => 0 },
    { down_bytes => 500, up_bytes => 25 },
]);
ok($vol->{down} == 1500 && $vol->{up} == 25 && $vol->{total} == 1525,
    'volume skips a null byte and keeps a stored zero');
my $none = SLMON::Dash::volume_bytes([{ down_bytes => undef, up_bytes => undef }]);
ok(!defined $none->{down} && !defined $none->{up} && !defined $none->{total},
    'a window of null bytes is not a zero');
my $tailed = SLMON::Dash::merge_unrolled(
    [{ ts_day => 86400, down_bytes => 100, up_bytes => 10 }],
    [
	{ ts_hour => 86400 + 3600, down_bytes => 999, up_bytes => 9 },
	{ ts_hour => 2 * 86400, down_bytes => 7, up_bytes => undef },
    ],
);
my $long = SLMON::Dash::volume_bytes($tailed);
ok(@$tailed == 2 && $long->{down} == 107 && $long->{up} == 10 && $long->{total} == 117,
    'a long window adds the unrolled hourly tail');
ok(SLMON::Dash::fmt_bytes(undef) eq 'n/a'
    && SLMON::Dash::fmt_bytes(0) eq '0 B'
    && SLMON::Dash::fmt_bytes(2_000_000_000) eq '2.0 GB'
    && SLMON::Dash::fmt_bytes(250_000_000) eq '250.0 MB',
    'byte totals use decimal units');
my $csv_rows = SLMON::Dash::merge_unrolled(
    [{ ts_day => 86400, down_bytes => 100, up_bytes => 10,
	avg_downlink_bps => 1, sample_count => 2 }],
    [
	{ ts_hour => 86400 + 3600, down_bytes => 999, up_bytes => 9 },
	{ ts_hour => 2 * 86400, down_bytes => 7, up_bytes => undef,
	    avg_downlink_bps => 4, sample_count => 1 },
    ],
);
my $csv_text = SLMON::Dash::csv_body($csv_rows);
ok($csv_text =~ /\Ats,down_bytes,up_bytes,/
    && $csv_text =~ /^86400,100,10,1,/m
    && $csv_text =~ /^172800,7,,4,/m
    && $csv_text !~ /999/,
    'csv is the window tier and leaves a null empty');
my $ever_html = SLMON::Dash::page({
    user => 'admin',
    range => 'ever',
    now => 1_700_000_000,
    series => [{
	ts_day => 1_600_000_000, avg_downlink_bps => 1_000_000, jitter_ms => 3,
    }],
});
ok($ever_html =~ m{<a href="/\?range=ever" aria-current="page">Ever</a>}
    && $ever_html =~ /cx="58\.0"/
    && $ever_html !~ /cx="6/
    && $ever_html !~ /1970/,
    'ever starts at the first stored sample');
ok(!SLMON::Dash::tier_has_obstr([{ avg_ping_latency_ms => 1 }]),
    'a rollup without obstruction is not ready');
ok(SLMON::Dash::tier_has_obstr([{ avg_obstr_fraction => 0 }]),
    'a zero obstruction fraction counts as stored');

my $oldcfg = SLMON::Config::parse('');
SLMON::Config::apply_paths($oldcfg, db_path => "$dir/old.db", root => '/none');
my $pre = DBI->connect("dbi:SQLite:dbname=$dir/old.db", '', '',
    { RaiseError => 1, PrintError => 0 });
$pre->do(q{CREATE TABLE metrics_minutely (
    id INTEGER PRIMARY KEY, ts_minute BIGINT NOT NULL UNIQUE,
    avg_obstr_fraction REAL, max_obstr_fraction REAL)});
$pre->do(q{CREATE TABLE metrics_hourly (
    id INTEGER PRIMARY KEY, ts_hour BIGINT NOT NULL UNIQUE,
    avg_obstr_fraction REAL)});
$pre->do(q{CREATE TABLE metrics_daily (
    id INTEGER PRIMARY KEY, ts_day BIGINT NOT NULL UNIQUE,
    avg_obstr_fraction REAL)});
$pre->disconnect;
my $oldh = SLMON::DB::open_db($oldcfg);
SLMON::DB::init_schema($oldh);
sub _colnames {
	my ($h, $table) = @_;
	my $info = $h->selectall_arrayref("PRAGMA table_info($table)");
	return map { $_->[1] => 1 } @$info;
}
my %mc = _colnames($oldh, 'metrics_minutely');
my %hc = _colnames($oldh, 'metrics_hourly');
my %dc = _colnames($oldh, 'metrics_daily');
ok($mc{jitter_ms} && $hc{jitter_ms} && $hc{max_obstr_fraction}
    && $hc{min_ping_latency_ms} && $dc{jitter_ms} && $dc{max_obstr_fraction},
    'an existing database gains the rollup columns');

my $sla = SLMON::Dash::sla([
	{ ts => 1000, type => 'ping_ok', details => 'ok' },
	{ ts => 1100, type => 'disconnect', details => 'down' },
	{ ts => 1400, type => 'disconnect', details => 'up', duration_s => 300 },
	{ ts => 2000, type => 'latency_spike', duration_s => 40, details => 'rtt_ms=9' },
	{ ts => 2500, type => 'obstruction', details => 'fraction=0.2' },
	{ ts => 3000, type => 'dish_outage', duration_s => 10,
	    details => 'cause=1 start_ns=2600000000000' },
], 1000, 4000);
my %hour;
$hour{(localtime($_))[2]}++ for (1100, 1960, 2600);
my $hours_ok = 1;
for my $h (0 .. 23) {
	$hours_ok = 0 if ($sla->{hours}[$h] || 0) != ($hour{$h} || 0);
}
ok(abs($sla->{uptime} - (2650 / 3000)) < 1e-9
    && $sla->{down_s} == 350
    && $sla->{longest_s} == 300
    && $sla->{mtbo_s} == 580
    && $sla->{n} == 3
    && $hours_ok,
    'sla ignores ping samples and pairs a disconnect');
my @open = SLMON::Dash::open_events([
	{ ts => 1000, type => 'disconnect', details => 'down' },
	{ ts => 1400, type => 'disconnect', details => 'up', duration_s => 300 },
	{ ts => 1800, type => 'disconnect', details => 'down' },
	{ ts => 2000, type => 'dish_outage', duration_s => 10,
	    details => 'cause=1 start_ns=1900000000000' },
	{ ts => 2100, type => 'obstruction', details => 'fraction=0.1' },
], 5000);
ok(@open == 1 && $open[0]{type} eq 'disconnect' && $open[0]{ts} == 1800,
    'an open event is a disconnect that has not come back');
my $top = SLMON::Dash::top_text({
	ts => 1800, downlink_bps => 10, uplink_bps => 2,
	ping_latency_ms => 5, ping_drop_rate => 0,
	obstr_fraction => 0.1, uptime_s => 9, device_id => 'SECRET',
}, [{ ts => 1800, type => 'disconnect', details => 'down' }], 2000);
ok($top =~ /\Alatest_ts: 1800\n/
    && $top =~ /down_bps: 10\n/
    && $top =~ /open:\n1800 disconnect down\n\z/
    && $top !~ /SECRET/,
    'top shows the latest sample and hides the device id');

my $bound = SLMON::Config::parse("listen = 127.0.0.1:0\nlisten = [::1]:0\n");
my @socks = SLMON::Parent::bind_listeners($bound);
ok(@socks == 2, 'parent binds ipv4 and ipv6 loopback');
my $held = $socks[0]->sockport;
my $busy = SLMON::Config::parse("listen = 127.0.0.1:$held\nlisten = 127.0.0.1:0\n");
my @rest = SLMON::Parent::bind_listeners($busy);
ok(@rest == 1 && $rest[0]->sockport != $held,
    'a failed listen line keeps the one that bound');
close $_ for @socks, @rest;

SLMON::DB::insert_metric($dbh, {
	ts => 9_000_000_000, downlink_bps => 42, uplink_bps => 7,
	ping_latency_ms => 11, ping_drop_rate => 0.5,
	obstr_fraction => 0.25, uptime_s => 99,
});
SLMON::DB::insert_event($dbh, {
	ts => 9_000_000_000, type => 'disconnect', details => 'down',
});
my $top_out = '';
open my $top_fh, '>', \$top_out;
my $old_fh = select $top_fh;
my $top_rc = SLMON::Parent::top($dbcfg);
select $old_fh;
close $top_fh;
ok($top_rc == 0
    && $top_out =~ /latest_ts: 9000000000\n/
    && $top_out =~ /down_bps: 42\n/
    && $top_out =~ /open:\n9000000000 disconnect down\n/,
    'slctl top reads the open database');

{
	open my $rc, '<', "$FindBin::Bin/../rc.d/sld" or die "rc.d/sld: $!";
	my $rcbody = do { local $/; <$rc> };
	close $rc;
	my $src_at = index($rcbody, ". /etc/rc.d/rc.subr\n");
	my $pexp_at = index($rcbody, "pexp=\"sld: parent\"\n");
	my $check_at = index($rcbody, "rc_check()");
	ok($src_at >= 0 && $pexp_at > $src_at && $check_at > $pexp_at
	    && $rcbody =~ /rc_check\(\) \{\n\tpexp="sld: parent"\n/,
	    'rc script sets the parent title after rc.subr');
}

my $top_now = 1_700_000_100;
my $top_page = {
	latest => {
		ts => $top_now, downlink_bps => 142_000_000, uplink_bps => 18_400_000,
		ping_latency_ms => 28, ping_drop_rate => 0,
		obstr_fraction => 0.00012, uptime_s => 4 * 86400 + 2 * 3600,
		device_id => 'SECRET', currently_obstructed => 0,
		obstruction_duration => 12, obstruction_interval => 40,
		direction_azimuth => 0, direction_elevation => 90,
		snr => 9.5, gps_sats => 8,
	},
	info => {
		device_id => 'SECRET', country_code => 'SECRET',
		hardware_version => 'rev1', software_version => 'sw1', bootcount => 4,
	},
	events => [{ ts => $top_now, type => 'disconnect', details => 'down' }],
	hour => [
		{ ts => $top_now - 100, downlink_bps => 142_000_000, uplink_bps => 1_000_000 },
		{ ts => $top_now - 10, downlink_bps => 1_000_000, uplink_bps => 18_400_000 },
	],
	series => [{
		ts_minute => $top_now - 60, down_bytes => 2_000_000, up_bytes => 3_000_000,
		avg_downlink_bps => 5_000_000, avg_uplink_bps => 1_000_000,
		avg_ping_latency_ms => 28, avg_ping_drop_rate => 0,
		avg_obstr_fraction => 0.01,
	}],
	obstruction => [{
		ts => $top_now - 60, ping_latency_ms => 28,
		ping_drop_rate => 0, obstr_fraction => 0.01,
	}],
	window_from => $top_now - 86400,
	window_to => $top_now,
	range => '24h',
	now => $top_now,
	cfg => {},
};
my $top_frame = SLMON::Top::frame($top_page,
	width => 100, view => 'overview', interval => 3, now => $top_now);
ok($top_frame =~ /overview/ && $top_frame =~ /every 3s/
    && $top_frame =~ /142\.0 Mbit\/s/ && $top_frame =~ /18\.4 Mbit\/s/
    && $top_frame =~ /uptime  4d 2h/
    && $top_frame =~ /open  1700000100 disconnect down/
    && $top_frame =~ /downlink, last hour/ && $top_frame =~ /#/
    && $top_frame =~ /-60m/ && $top_frame !~ /SECRET/
    && $top_frame !~ /device_id/ && $top_frame !~ / stale/,
    'overview frame shows rates, the hour chart, and open events');
my $stale = SLMON::Top::frame($top_page,
	width => 100, now => $top_now + 121);
ok($stale =~ / stale/, 'a sample older than 120 seconds is stale');
my $narrow = SLMON::Top::frame($top_page, width => 40, now => $top_now);
my $narrow_ok = ($narrow =~ /chart needs a wider terminal/)
    && ($narrow =~ /142\.0 Mbit\/s/)
    && ($narrow =~ /q quit/);
ok($narrow_ok, 'a narrow terminal keeps the numbers and the keys');
sub _plot_height {
	my ($text, $title) = @_;
	my ($n, $on) = (0, 0);
	for my $line (split /\n/, $text) {
		if (index($line, $title) == 0) {
			$on = 1;
			next;
		}
		next if !$on;
		last if $line =~ /\+/;
		$n++ if $line =~ /\|/;
	}
	return $n;
}
my $ov24 = SLMON::Top::frame($top_page,
	width => 100, height => 24, view => 'overview', now => $top_now);
my $ov40 = SLMON::Top::frame($top_page,
	width => 100, height => 40, view => 'overview', now => $top_now);
my $p24 = _plot_height($ov24, 'downlink, last hour');
my $p40 = _plot_height($ov40, 'downlink, last hour');
my $ov_grow = ($p40 > $p24) && ($p24 > 3)
    && (scalar(split /\n/, $ov24) == 24)
    && (scalar(split /\n/, $ov40) == 40);
ok($ov_grow, 'overview charts grow with the terminal');
my $q24 = SLMON::Top::frame($top_page,
	width => 100, height => 24, view => 'quality', range => '24h',
	now => $top_now);
my $q48 = SLMON::Top::frame($top_page,
	width => 100, height => 48, view => 'quality', range => '24h',
	now => $top_now);
my $q_grow = _plot_height($q48, 'latency, 24h')
    > _plot_height($q24, 'latency, 24h');
ok($q_grow, 'quality charts grow with the terminal');
sub _time_under {
	my ($text, $title) = @_;
	my ($arm, $prev) = (0, '');
	for my $line (split /\n/, $text) {
		if (index($line, $title) == 0) {
			$arm = 1;
			$prev = '';
			next;
		}
		next if !$arm;
		return ($prev, $line) if $prev =~ /\A *\+\-/;
		$prev = $line;
	}
	return ('', '');
}
sub _ago_secs {
	my ($lab) = @_;
	return 0 if $lab eq 'now';
	return $1 * 86400 + $2 * 3600 if $lab =~ /\A-(\d+)d(\d+)h\z/;
	return $1 * 86400 if $lab =~ /\A-(\d+)d\z/;
	return $1 * 3600 if $lab =~ /\A-(\d+)h\z/;
	return $1 * 60 if $lab =~ /\A-(\d+)m\z/;
	return $1 if $lab =~ /\A-(\d+)s\z/;
	return -1;
}
# Count of even labels under $title, or 0 when the line is wrong.
# The first label sits on the first dash and the last sits on the last.
sub _axis_even {
	my ($text, $title, $span) = @_;
	my ($base, $time) = _time_under($text, $title);
	return 0 if $base !~ /\A *\+\-/ || $time eq '';
	my $dash = index($base, '-');
	my $end = rindex($base, '-');
	return 0 if $dash < 0 || $end < $dash;
	return 0 if length($time) < $end + 1;
	my $body = substr($time, $dash, $end - $dash + 1);
	return 0 if $body =~ /\A / || $body !~ /now\z/;
	my (@labs, @at);
	while ($body =~ /(\S+)/g) {
		push @labs, $1;
		push @at, [$-[0], $+[0]];
	}
	return 0 if @labs < 2;
	for my $i (1 .. $#labs) {
		return 0 if $at[$i][0] < $at[$i - 1][1] + 2;
	}
	my @ago = map { _ago_secs($_) } @labs;
	return 0 if $ago[0] != $span || $ago[-1] != 0;
	my $step = $ago[0] - $ago[1];
	return 0 if $step <= 0;
	for my $i (1 .. $#ago) {
		return 0 if $ago[$i - 1] - $ago[$i] != $step;
	}
	return scalar @labs;
}
my $ov80 = SLMON::Top::frame($top_page,
	width => 80, view => 'overview', now => $top_now);
my $ov160 = SLMON::Top::frame($top_page,
	width => 160, view => 'overview', now => $top_now);
my $hour80 = _axis_even($ov80, 'downlink, last hour', 3600);
my $hour160 = _axis_even($ov160, 'downlink, last hour', 3600);
my $up160 = _axis_even($ov160, 'uplink, last hour', 3600);
my $hour_axis = ($hour80 >= 2) && ($hour160 > $hour80) && ($up160 == $hour160);
ok($hour_axis, 'overview time labels stay even and thicken as the terminal widens');
my $q80 = SLMON::Top::frame($top_page,
	width => 80, view => 'quality', range => '24h', now => $top_now);
my $q160 = SLMON::Top::frame($top_page,
	width => 160, view => 'quality', range => '24h', now => $top_now);
my $lat80 = _axis_even($q80, 'latency, 24h', 86400);
my $lat160 = _axis_even($q160, 'latency, 24h', 86400);
my $ob160 = _axis_even($q160, 'obstruction, 24h', 86400);
my $day_axis = ($lat80 >= 2) && ($lat160 > $lat80) && ($ob160 == $lat160);
ok($day_axis, 'quality time labels stay even and thicken as the terminal widens');
my $week_page = { %$top_page, range => '7d', window_from => $top_now - 7 * 86400 };
my $week80 = SLMON::Top::frame($week_page,
	width => 80, view => 'quality', range => '7d', now => $top_now);
my $week160 = SLMON::Top::frame($week_page,
	width => 160, view => 'quality', range => '7d', now => $top_now);
my $week_line = (_time_under($week80, 'latency, 7d'))[1];
my $week_line_w = (_time_under($week160, 'latency, 7d'))[1];
my $week80n = _axis_even($week80, 'latency, 7d', 7 * 86400);
my $week160n = _axis_even($week160, 'latency, 7d', 7 * 86400);
my $week_axis = ($week80n >= 2) && ($week160n > $week80n)
    && ($week_line !~ /-\d{3,}h/) && ($week_line_w !~ /-\d{3,}h/);
ok($week_axis, 'a week of quality labels stays in days as the terminal changes');
my $year_page = { %$top_page, range => '365d', window_from => $top_now - 365 * 86400 };
my $year = SLMON::Top::frame($year_page,
	width => 100, view => 'quality', range => '365d', now => $top_now);
my $year_n = _axis_even($year, 'latency, 365d', 365 * 86400);
ok($year_n == 2, 'a year chart marks the two ends when finer ticks do not fit');
my $throughput = SLMON::Top::frame($top_page,
	width => 100, view => 'throughput', range => '24h', now => $top_now);
ok($throughput =~ /bytes down/ && $throughput =~ /2\.0 MB/
    && $throughput =~ /bytes total/ && $throughput =~ /5\.0 MB/,
    'throughput shows byte totals and the window rate');
my $top_quiet = SLMON::Top::frame({
	%$top_page,
	weather => [{ ts => $top_now, warning => 'thunderstorm' }],
    }, width => 100, view => 'quality', now => $top_now);
ok($top_quiet =~ /latency, 24h/ && $top_quiet !~ /thunderstorm/,
    'quality omits weather when coordinates are unset');
my $top_storm = SLMON::Top::frame({
	%$top_page,
	cfg => { latitude => '44', longitude => '-92' },
	weather => [{ ts => $top_now, warning => 'thunderstorm' }],
    }, width => 100, view => 'quality', now => $top_now);
ok($top_storm =~ /weather  thunderstorm/ && $top_storm =~ /latency, 24h/,
    'quality names the stored weather warning');
my @cell;
for my $r (0 .. 7) {
	for my $c (0 .. 7) {
		push @cell, $r == 0 ? -1 : ($c < 4 ? 0 : 1.5);
	}
}
my $dish = SLMON::Top::frame({
	%$top_page,
	map => {
		num_rows => 8, num_cols => 8,
		snr_b64 => encode_base64(pack('f<*', @cell), ''),
	},
    }, width => 100, view => 'dish', now => $top_now);
ok($dish =~ /rev1/ && $dish =~ /boot 4/ && $dish =~ /#/ && $dish =~ /\./
    && $dish =~ /\+/ && $dish =~ /currently  no/
    && $dish !~ /SECRET/ && $dish !~ /device_id/,
    'dish view draws the map and hides the device id');
sub _map_box {
	my ($text) = @_;
	my ($wide, $high, $on) = (0, 0, 0);
	for my $line (split /\n/, $text) {
		if ($line =~ /map  space unmeasured/) {
			$on = 1;
			next;
		}
		next if !$on;
		last if $line !~ /\A[ .+#]+\z/;
		$high++;
		$wide = length($line) if length($line) > $wide;
	}
	return ($wide, $high);
}
my $dish_map = {
	num_rows => 8, num_cols => 8,
	snr_b64 => encode_base64(pack('f<*', @cell), ''),
};
my $dish_big = SLMON::Top::frame({ %$top_page, map => $dish_map },
	width => 120, height => 40, view => 'dish', now => $top_now);
my $dish_small = SLMON::Top::frame({ %$top_page, map => $dish_map },
	width => 40, height => 18, view => 'dish', now => $top_now);
my ($map_bw, $map_bh) = _map_box($dish_big);
my ($map_sw, $map_sh) = _map_box($dish_small);
my $map_fit = ($map_bw > $map_sw) && ($map_bh > $map_sh)
    && ($map_bw > 40) && ($dish_big =~ /\+/) && ($dish_small =~ /\+/);
ok($map_fit, 'dish map grows and shrinks with the terminal');
my $nomap = SLMON::Top::frame($top_page, width => 100, view => 'dish', now => $top_now);
ok($nomap =~ /no obstruction map stored/, 'a missing map is said in words');
my @hours = (0) x 24;
$hours[3] = 2;
my $hist = SLMON::Top::frame({
	%$top_page,
	sla => {
		uptime => 0.9, longest_s => 30, mtbo_s => 10,
		busiest => 3, hours => \@hours,
	},
	sla_events => [
		{ ts => $top_now - 80000, type => 'disconnect', details => 'down' },
		{ ts => $top_now - 79700, type => 'disconnect', details => 'up',
		    duration_s => 300 },
		{ ts => $top_now - 100, type => 'ping_ok', details => 'ok' },
		{ ts => $top_now - 50, type => 'obstruction', details => 'fraction=0.2' },
	],
	events => [
		{ ts => $top_now - 100, type => 'ping_ok', details => 'ok' },
		{ ts => $top_now - 79700, type => 'disconnect', details => 'up' },
	],
    }, width => 100, view => 'history', now => $top_now);
ok($hist =~ /uptime  90\.000%/ && $hist =~ /calendar  [#.]+/
    && $hist =~ /#/ && $hist =~ /\./
    && $hist =~ /disconnect up/ && $hist !~ /ping_ok/,
    'history shows uptime and a one-row calendar');
my $cfg_frame = SLMON::Top::frame({
	%$top_page,
	cfg => {
		db => 'sqlite', db_path => '/tmp/sl.db',
		listen => '127.0.0.1:8080', dish_host => '192.168.100.1',
		dish_interval_s => 30, admin_pass_hash => 'SECRET',
		session_secret => 'SECRET', pg_password => 'SECRET',
	},
	initialized => 'yes', http_port => '8080', history_n => 3,
	view_meta => {
		db => 'sqlite', dish_host => '192.168.100.1', dish_port => 9200,
		sample_s => 30, map_s => 300, listen => '127.0.0.1:8080',
		raw_days => 90, minute_days => 730, hour_days => 365,
	},
    }, width => 100, view => 'config', now => $top_now);
ok($cfg_frame =~ /initialized  yes/ && $cfg_frame =~ /listen  127\.0\.0\.1:8080/
    && $cfg_frame =~ /retention  raw 90d/ && $cfg_frame !~ /SECRET/,
    'config shows listen and retention and hides the password');
my $keys = { view => 'overview', range => '7d', interval => 3 };
ok(SLMON::Top::apply_key($keys, 'H') && $keys->{range} eq '24h', 'H selects 24h');
ok(SLMON::Top::apply_key($keys, 'l') && $keys->{view} eq 'quality',
    'l selects quality');
ok(SLMON::Top::apply_key($keys, '+') && $keys->{interval} == 4,
    'plus lengthens the interval');
$keys->{interval} = 1;
ok(SLMON::Top::apply_key($keys, '-') && $keys->{interval} == 1,
    'minus stops at 1 second');
ok(!SLMON::Top::apply_key($keys, 'q') && !SLMON::Top::apply_key($keys, 'Q'),
    'q quits');

SLMON::DB::upsert_dish_info($dbh, {
	device_id => 'SECRET', hardware_version => 'rev1',
	software_version => 'sw1', country_code => 'SECRET',
	bootcount => 4, last_seen_ts => 9_000_000_000,
});
my $loaded = eval { SLMON::Top::load($dbh, $dbcfg, '24h', time) };
my $loaded_dish = $loaded
    ? SLMON::Top::frame($loaded, width => 100, view => 'dish', now => time)
    : '';
ok($loaded && $loaded_dish =~ /rev1/ && $loaded_dish =~ /boot 4/
    && $loaded_dish =~ /no obstruction map stored/ && $loaded_dish !~ /SECRET/,
    'top load reads the database and hides the device id');

sub _slctl_out {
	my (@args) = @_;
	my $pid = open my $fh, '-|';
	die "fork: $!" if !defined $pid;
	if ($pid == 0) {
		open STDERR, '>&STDOUT';
		exec $^X, "$FindBin::Bin/../bin/slctl", @args;
		die "exec: $!";
	}
	my $text = '';
	eval {
		local $SIG{ALRM} = sub { die "hung\n" };
		alarm 5;
		$text = do { local $/; <$fh> };
		alarm 0;
	};
	if ($@) {
		kill 'TERM', $pid;
		close $fh;
		return ('', 1);
	}
	close $fh;
	return ($text, $?);
}
my ($piped, $piped_rc) = _slctl_out('top', '-d', "$dir/t.db");
ok(!$piped_rc && $piped =~ /latest_ts: 9000000000\n/
    && $piped =~ /down_bps: 42\n/ && $piped !~ /SECRET/,
    'a pipe gets one sample from slctl top');
my ($once_out, $once_rc) = _slctl_out('-0', 'top', '-d', "$dir/t.db");
ok(!$once_rc && $once_out =~ /latest_ts: 9000000000\n/ && $once_out !~ /SECRET/,
    'slctl -0 top prints one sample');
my ($zero_out, $zero_rc) = _slctl_out('top', '0', '-d', "$dir/t.db");
ok($zero_rc && $zero_out =~ /at least 1/, 'top rejects an interval of 0');
my ($flag_out, $flag_rc) = _slctl_out('-0', 'status');
ok($flag_rc && $flag_out =~ /-0 applies to top/, '-0 applies only to top');

print "$n tests, $fail failed\n";
exit($fail ? 1 : 0);
