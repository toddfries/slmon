package SLMON::Rollup;

use strict;
use warnings;

sub _intb {
	my ($v) = @_;
	return 0 if !defined $v;
	return int($v / 8);
}

sub roll_minutes {
	my ($dbh, $now) = @_;
	my ($last) = $dbh->selectrow_array(
	    'SELECT last_rolled_minute FROM collector_state WHERE id = 1');
	$last = 0 if !defined $last;
	my $end = $now - ($now % 60);
	return 0 if $end <= 60;
	# Keep the newest completed minute open. A poll often arrives just
	# after the boundary with that minute's samples, and the first poll
	# can carry a day of ring history. An empty roll must not close the
	# cursor or those samples never land.
	my $open = $end - 60;
	my $start;
	if (!$last) {
		$start = $end - 86400;
		$start = 0 if $start < 0;
	} else {
		$start = $last > $open ? $open : $last;
		if ($end - $start > 86400) {
			$start = $end - 86400;
		}
	}
	return 0 if $end <= $start;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT (ts - (ts % 60)) AS ts_minute,
		       AVG(ping_drop_rate) AS avg_ping_drop_rate,
		       AVG(ping_latency_ms) AS avg_ping_latency_ms,
		       MIN(ping_latency_ms) AS min_ping_latency_ms,
		       MAX(ping_latency_ms) AS max_ping_latency_ms,
		       AVG(downlink_bps) AS avg_downlink_bps,
		       MIN(downlink_bps) AS min_downlink_bps,
		       MAX(downlink_bps) AS max_downlink_bps,
		       AVG(uplink_bps) AS avg_uplink_bps,
		       MIN(uplink_bps) AS min_uplink_bps,
		       MAX(uplink_bps) AS max_uplink_bps,
		       SUM(downlink_bps) AS sum_down,
		       SUM(uplink_bps) AS sum_up,
		       COUNT(*) AS sample_count
		FROM history_samples
		WHERE ts >= ? AND ts < ?
		GROUP BY (ts - (ts % 60))
		ORDER BY ts_minute
	}, { Slice => {} }, $start, $end);
	my $sth = $dbh->prepare(q{
		INSERT INTO metrics_minutely (
		    ts_minute, avg_ping_drop_rate, avg_ping_latency_ms,
		    min_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, max_obstr_fraction,
		    avg_downlink_bps, min_downlink_bps, max_downlink_bps,
		    avg_uplink_bps, min_uplink_bps, max_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (ts_minute) DO UPDATE SET
		    avg_ping_drop_rate = excluded.avg_ping_drop_rate,
		    avg_ping_latency_ms = excluded.avg_ping_latency_ms,
		    min_ping_latency_ms = excluded.min_ping_latency_ms,
		    max_ping_latency_ms = excluded.max_ping_latency_ms,
		    avg_downlink_bps = excluded.avg_downlink_bps,
		    min_downlink_bps = excluded.min_downlink_bps,
		    max_downlink_bps = excluded.max_downlink_bps,
		    avg_uplink_bps = excluded.avg_uplink_bps,
		    min_uplink_bps = excluded.min_uplink_bps,
		    max_uplink_bps = excluded.max_uplink_bps,
		    down_bytes = excluded.down_bytes,
		    up_bytes = excluded.up_bytes,
		    sample_count = excluded.sample_count
	});
	for my $r (@$rows) {
		$sth->execute(
		    $r->{ts_minute},
		    $r->{avg_ping_drop_rate}, $r->{avg_ping_latency_ms},
		    $r->{min_ping_latency_ms}, $r->{max_ping_latency_ms},
		    undef, undef,
		    $r->{avg_downlink_bps}, $r->{min_downlink_bps}, $r->{max_downlink_bps},
		    $r->{avg_uplink_bps}, $r->{min_uplink_bps}, $r->{max_uplink_bps},
		    _intb($r->{sum_down}), _intb($r->{sum_up}),
		    $r->{sample_count},
		);
	}
	if (!@$rows && !$last) {
		return 0;
	}
	$dbh->do('UPDATE collector_state SET last_rolled_minute = ? WHERE id = 1',
	    undef, $open);
	return scalar @$rows;
}

sub roll_hours {
	my ($dbh, $now) = @_;
	my $end = $now - ($now % 3600);
	return 0 if $end <= 0;
	my $start = $end - 2 * 86400;
	$start = 0 if $start < 0;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT (ts_minute - (ts_minute % 3600)) AS ts_hour,
		       AVG(avg_ping_drop_rate) AS avg_ping_drop_rate,
		       AVG(avg_ping_latency_ms) AS avg_ping_latency_ms,
		       MAX(max_ping_latency_ms) AS max_ping_latency_ms,
		       AVG(avg_obstr_fraction) AS avg_obstr_fraction,
		       AVG(avg_downlink_bps) AS avg_downlink_bps,
		       AVG(avg_uplink_bps) AS avg_uplink_bps,
		       SUM(down_bytes) AS down_bytes,
		       SUM(up_bytes) AS up_bytes,
		       SUM(sample_count) AS sample_count
		FROM metrics_minutely
		WHERE ts_minute >= ? AND ts_minute < ?
		GROUP BY (ts_minute - (ts_minute % 3600))
	}, { Slice => {} }, $start, $end);
	my $sth = $dbh->prepare(q{
		INSERT INTO metrics_hourly (
		    ts_hour, avg_ping_drop_rate, avg_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		VALUES (?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (ts_hour) DO UPDATE SET
		    avg_ping_drop_rate = excluded.avg_ping_drop_rate,
		    avg_ping_latency_ms = excluded.avg_ping_latency_ms,
		    max_ping_latency_ms = excluded.max_ping_latency_ms,
		    avg_obstr_fraction = excluded.avg_obstr_fraction,
		    avg_downlink_bps = excluded.avg_downlink_bps,
		    avg_uplink_bps = excluded.avg_uplink_bps,
		    down_bytes = excluded.down_bytes,
		    up_bytes = excluded.up_bytes,
		    sample_count = excluded.sample_count
	});
	for my $r (@$rows) {
		$sth->execute(
		    $r->{ts_hour}, $r->{avg_ping_drop_rate}, $r->{avg_ping_latency_ms},
		    $r->{max_ping_latency_ms}, $r->{avg_obstr_fraction},
		    $r->{avg_downlink_bps}, $r->{avg_uplink_bps},
		    $r->{down_bytes}, $r->{up_bytes}, $r->{sample_count},
		);
	}
	return scalar @$rows;
}

sub roll_days {
	my ($dbh, $now) = @_;
	my $end = $now - ($now % 86400);
	return 0 if $end <= 0;
	my $start = $end - 40 * 86400;
	$start = 0 if $start < 0;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT (ts_hour - (ts_hour % 86400)) AS ts_day,
		       AVG(avg_ping_drop_rate) AS avg_ping_drop_rate,
		       AVG(avg_ping_latency_ms) AS avg_ping_latency_ms,
		       MAX(max_ping_latency_ms) AS max_ping_latency_ms,
		       AVG(avg_obstr_fraction) AS avg_obstr_fraction,
		       AVG(avg_downlink_bps) AS avg_downlink_bps,
		       AVG(avg_uplink_bps) AS avg_uplink_bps,
		       SUM(down_bytes) AS down_bytes,
		       SUM(up_bytes) AS up_bytes,
		       SUM(sample_count) AS sample_count
		FROM metrics_hourly
		WHERE ts_hour >= ? AND ts_hour < ?
		GROUP BY (ts_hour - (ts_hour % 86400))
	}, { Slice => {} }, $start, $end);
	my $sth = $dbh->prepare(q{
		INSERT INTO metrics_daily (
		    ts_day, avg_ping_drop_rate, avg_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		VALUES (?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (ts_day) DO UPDATE SET
		    avg_ping_drop_rate = excluded.avg_ping_drop_rate,
		    avg_ping_latency_ms = excluded.avg_ping_latency_ms,
		    max_ping_latency_ms = excluded.max_ping_latency_ms,
		    avg_obstr_fraction = excluded.avg_obstr_fraction,
		    avg_downlink_bps = excluded.avg_downlink_bps,
		    avg_uplink_bps = excluded.avg_uplink_bps,
		    down_bytes = excluded.down_bytes,
		    up_bytes = excluded.up_bytes,
		    sample_count = excluded.sample_count
	});
	for my $r (@$rows) {
		$sth->execute(
		    $r->{ts_day}, $r->{avg_ping_drop_rate}, $r->{avg_ping_latency_ms},
		    $r->{max_ping_latency_ms}, $r->{avg_obstr_fraction},
		    $r->{avg_downlink_bps}, $r->{avg_uplink_bps},
		    $r->{down_bytes}, $r->{up_bytes}, $r->{sample_count},
		);
	}
	return scalar @$rows;
}

# Rows strictly older than the window are compressed or deleted.
# A row one second newer than the cut stays.
sub retain {
	my ($dbh, $now, $raw_days, $hourly_days, $minutely_days) = @_;
	my $raw_cut = $now - $raw_days * 86400;
	my $hour_cut = $now - $hourly_days * 86400;
	my $min_cut = $now - $minutely_days * 86400;

	$dbh->do(q{
		INSERT INTO metrics_hourly (
		    ts_hour, avg_ping_drop_rate, avg_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		SELECT (ts - (ts % 3600)),
		       AVG(ping_drop_rate),
		       AVG(ping_latency_ms),
		       MAX(ping_latency_ms),
		       NULL,
		       AVG(downlink_bps),
		       AVG(uplink_bps),
		       CAST(SUM(downlink_bps) AS BIGINT) / 8,
		       CAST(SUM(uplink_bps) AS BIGINT) / 8,
		       COUNT(*)
		FROM history_samples
		WHERE ts < ?
		GROUP BY (ts - (ts % 3600))
		ON CONFLICT (ts_hour) DO NOTHING
	}, undef, $raw_cut);
	$dbh->do('DELETE FROM history_samples WHERE ts < ?', undef, $raw_cut);
	$dbh->do('DELETE FROM metrics WHERE ts < ?', undef, $raw_cut);

	$dbh->do(q{
		INSERT INTO metrics_daily (
		    ts_day, avg_ping_drop_rate, avg_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		SELECT (ts_hour - (ts_hour % 86400)),
		       AVG(avg_ping_drop_rate),
		       AVG(avg_ping_latency_ms),
		       MAX(max_ping_latency_ms),
		       AVG(avg_obstr_fraction),
		       AVG(avg_downlink_bps),
		       AVG(avg_uplink_bps),
		       SUM(down_bytes),
		       SUM(up_bytes),
		       SUM(sample_count)
		FROM metrics_hourly
		WHERE ts_hour < ?
		GROUP BY (ts_hour - (ts_hour % 86400))
		ON CONFLICT (ts_day) DO NOTHING
	}, undef, $hour_cut);
	$dbh->do('DELETE FROM metrics_hourly WHERE ts_hour < ?', undef, $hour_cut);
	$dbh->do('DELETE FROM metrics_minutely WHERE ts_minute < ?', undef, $min_cut);
	$dbh->do('UPDATE collector_state SET last_retain_day = ? WHERE id = 1',
	    undef, $now - ($now % 86400));
	return;
}

1;
