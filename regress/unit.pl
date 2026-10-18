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
use SLMON::Http;
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
ok($cfg->{dish_host} eq '192.168.100.1', 'default dish host');
ok($cfg->{rollup_interval_s} == 60, 'default rollup interval');
ok($cfg->{raw_retention_days} == 90, 'default raw retention');
eval { SLMON::Config::parse("nope = 1\n") };
ok($@ && $@ =~ /unknown config key/, 'unknown key rejected');
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
SLMON::Rollup::roll_hours($dbh, $day + 3600);
my ($hbytes) = $dbh->selectrow_array(
    'SELECT down_bytes FROM metrics_hourly WHERE ts_hour = ?', undef, $day);
ok(defined $hbytes && $hbytes == 60000, 'hourly rollup');
SLMON::Rollup::roll_days($dbh, $day + 86400);
my ($dbytes) = $dbh->selectrow_array(
    'SELECT down_bytes FROM metrics_daily WHERE ts_day = ?', undef, $day);
ok(defined $dbytes && $dbytes == 60000, 'daily rollup');

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
SLMON::DB::insert_metric($dbh, { ts => $raw_cut - 1, ping_drop_rate => 0, alerts_bitfield => 0 });
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
		query   => {},
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
my $root = SLMON::Http::respond(http_req('GET', '/'), $hctx);
ok($root =~ m{\AHTTP/1.0 303 } && $root =~ m{Location: /login},
    'root sends a browser to the login form');
my $tok = SLMON::Auth::sign_session('admin', time + 3600, $secret);
my $home = SLMON::Http::respond(http_req('GET', '/',
    headers => { cookie => "slmon_session=$tok" }), $hctx);
ok($home =~ /Signed in as admin/ && $home =~ m{/api/latest/history_samples}
    && $home =~ m{action="/logout"},
    'home after login');
my $again = SLMON::Http::respond(http_req('GET', '/login',
    headers => { cookie => "slmon_session=$tok" }), $hctx);
ok($again =~ m{\AHTTP/1.0 303 } && $again =~ m{Location: /},
    'login form redirects when already signed in');
my $out = SLMON::Http::respond(http_req('POST', '/logout'), $hctx);
ok($out =~ m{\AHTTP/1.0 303 } && $out =~ m{Location: /login}
    && $out =~ /Max-Age=0/,
    'logout clears the cookie');
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

print "$n tests, $fail failed\n";
exit($fail ? 1 : 0);
