package SLMON::Rollup;

use strict;
use warnings;

# Jitter is the latency spread in the bucket: max minus min.
# A coarser row uses the finer rows' min and max, not the average of their spreads.
sub _spread {
	my ($min, $max) = @_;
	return undef if !defined $min || !defined $max;
	return $max - $min;
}

sub _debug {
	my ($cfg, $msg) = @_;
	return if !ref $cfg || ($cfg->{log_level} // '') ne 'debug';
	warn "sld: $msg\n";
	return;
}

sub _intb {
	my ($v) = @_;
	return 0 if !defined $v;
	return int($v / 8);
}

# One pass per database handle. Later rolls write new buckets directly.
# Rows whose source samples are already gone stay null.
sub fill_gaps {
	my ($dbh, $cfg) = @_;
	my $mj = _fill_minute_jitter($dbh);
	my $mo = _fill_minute_obstr($dbh);
	my $hours = _fill_coarser($dbh,
	    dst => 'metrics_hourly', dcol => 'ts_hour',
	    src => 'metrics_minutely', scol => 'ts_minute', mod => 3600);
	my $days = _fill_coarser($dbh,
	    dst => 'metrics_daily', dcol => 'ts_day',
	    src => 'metrics_hourly', scol => 'ts_hour', mod => 86400);
	_debug($cfg, "rollup fill minute_jitter=$mj minute_obstr=$mo hours=$hours days=$days");
	return;
}

sub _fill_minute_jitter {
	my ($dbh) = @_;
	my ($need) = $dbh->selectrow_array(
	    'SELECT 1 FROM metrics_minutely WHERE jitter_ms IS NULL LIMIT 1');
	return 0 if !$need;
	my ($lo, $hi) = $dbh->selectrow_array(
	    'SELECT MIN(ts), MAX(ts) FROM history_samples WHERE ping_latency_ms IS NOT NULL');
	return 0 if !defined $lo;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT (ts - (ts % 60)) AS ts_minute,
		       MIN(ping_latency_ms) AS min_l,
		       MAX(ping_latency_ms) AS max_l
		FROM history_samples
		WHERE ts >= ? AND ts <= ?
		GROUP BY (ts - (ts % 60))
	}, { Slice => {} }, $lo, $hi);
	my $sth = $dbh->prepare(q{
		UPDATE metrics_minutely SET
		    jitter_ms = ?,
		    min_ping_latency_ms = COALESCE(min_ping_latency_ms, ?),
		    max_ping_latency_ms = COALESCE(max_ping_latency_ms, ?)
		WHERE ts_minute = ? AND jitter_ms IS NULL
	});
	my $n = 0;
	for my $r (@$rows) {
		my $j = _spread($r->{min_l}, $r->{max_l});
		next if !defined $j;
		my $rv = $sth->execute($j, $r->{min_l}, $r->{max_l}, $r->{ts_minute});
		$n += $rv if $rv && $rv > 0;
	}
	return $n;
}

sub _fill_minute_obstr {
	my ($dbh) = @_;
	my ($need) = $dbh->selectrow_array(
	    'SELECT 1 FROM metrics_minutely WHERE avg_obstr_fraction IS NULL LIMIT 1');
	return 0 if !$need;
	my ($lo, $hi) = $dbh->selectrow_array(
	    'SELECT MIN(ts), MAX(ts) FROM metrics WHERE obstr_fraction IS NOT NULL');
	return 0 if !defined $lo;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT (ts - (ts % 60)) AS ts_minute,
		       AVG(obstr_fraction) AS avg_o,
		       MAX(obstr_fraction) AS max_o
		FROM metrics
		WHERE ts >= ? AND ts <= ? AND obstr_fraction IS NOT NULL
		GROUP BY (ts - (ts % 60))
	}, { Slice => {} }, $lo, $hi);
	my $sth = $dbh->prepare(q{
		UPDATE metrics_minutely
		SET avg_obstr_fraction = ?, max_obstr_fraction = ?
		WHERE ts_minute = ? AND avg_obstr_fraction IS NULL
	});
	my $n = 0;
	for my $r (@$rows) {
		next if !defined $r->{avg_o};
		my $rv = $sth->execute($r->{avg_o}, $r->{max_o}, $r->{ts_minute});
		$n += $rv if $rv && $rv > 0;
	}
	return $n;
}

# $dst, $src, and the column names are the rollup tables, not operator input.
sub _fill_coarser {
	my ($dbh, %o) = @_;
	my ($dst, $dcol, $src, $scol, $mod) = @o{qw(dst dcol src scol mod)};
	my ($need) = $dbh->selectrow_array(qq{
		SELECT 1 FROM $dst
		WHERE jitter_ms IS NULL OR avg_obstr_fraction IS NULL
		   OR max_obstr_fraction IS NULL
		LIMIT 1
	});
	return 0 if !$need;
	my $rows = $dbh->selectall_arrayref(qq{
		SELECT ($scol - ($scol % $mod)) AS bucket,
		       AVG(avg_obstr_fraction) AS avg_o,
		       MAX(max_obstr_fraction) AS max_o,
		       MIN(min_ping_latency_ms) AS min_l,
		       MAX(max_ping_latency_ms) AS max_l
		FROM $src
		GROUP BY ($scol - ($scol % $mod))
	}, { Slice => {} });
	my $sth = $dbh->prepare(qq{
		UPDATE $dst SET
		    avg_obstr_fraction = COALESCE(avg_obstr_fraction, ?),
		    max_obstr_fraction = COALESCE(max_obstr_fraction, ?),
		    min_ping_latency_ms = COALESCE(min_ping_latency_ms, ?),
		    jitter_ms = COALESCE(jitter_ms, ?)
		WHERE $dcol = ?
		  AND (jitter_ms IS NULL OR avg_obstr_fraction IS NULL
		       OR max_obstr_fraction IS NULL OR min_ping_latency_ms IS NULL)
	});
	my $n = 0;
	for my $r (@$rows) {
		my $j = _spread($r->{min_l}, $r->{max_l});
		my $rv = $sth->execute($r->{avg_o}, $r->{max_o}, $r->{min_l}, $j, $r->{bucket});
		$n += $rv if $rv && $rv > 0;
	}
	return $n;
}

sub roll_minutes {
	my ($dbh, $now, $cfg) = @_;
	if (!$dbh->{private_slmon_gaps_done}) {
		fill_gaps($dbh, $cfg);
		$dbh->{private_slmon_gaps_done} = 1;
	}
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
	my $obrows = $dbh->selectall_arrayref(q{
		SELECT (ts - (ts % 60)) AS ts_minute,
		       AVG(obstr_fraction) AS avg_obstr_fraction,
		       MAX(obstr_fraction) AS max_obstr_fraction
		FROM metrics
		WHERE ts >= ? AND ts < ? AND obstr_fraction IS NOT NULL
		GROUP BY (ts - (ts % 60))
	}, { Slice => {} }, $start, $end);
	my %ob = map { $_->{ts_minute} => $_ } @$obrows;
	my $sth = $dbh->prepare(q{
		INSERT INTO metrics_minutely (
		    ts_minute, avg_ping_drop_rate, avg_ping_latency_ms,
		    min_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, max_obstr_fraction, jitter_ms,
		    avg_downlink_bps, min_downlink_bps, max_downlink_bps,
		    avg_uplink_bps, min_uplink_bps, max_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (ts_minute) DO UPDATE SET
		    avg_ping_drop_rate = excluded.avg_ping_drop_rate,
		    avg_ping_latency_ms = excluded.avg_ping_latency_ms,
		    min_ping_latency_ms = excluded.min_ping_latency_ms,
		    max_ping_latency_ms = excluded.max_ping_latency_ms,
		    avg_obstr_fraction = excluded.avg_obstr_fraction,
		    max_obstr_fraction = excluded.max_obstr_fraction,
		    jitter_ms = excluded.jitter_ms,
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
	my $with = 0;
	for my $r (@$rows) {
		my $o = $ob{$r->{ts_minute}} || {};
		$with++ if defined $o->{avg_obstr_fraction};
		$sth->execute(
		    $r->{ts_minute},
		    $r->{avg_ping_drop_rate}, $r->{avg_ping_latency_ms},
		    $r->{min_ping_latency_ms}, $r->{max_ping_latency_ms},
		    $o->{avg_obstr_fraction}, $o->{max_obstr_fraction},
		    _spread($r->{min_ping_latency_ms}, $r->{max_ping_latency_ms}),
		    $r->{avg_downlink_bps}, $r->{min_downlink_bps}, $r->{max_downlink_bps},
		    $r->{avg_uplink_bps}, $r->{min_uplink_bps}, $r->{max_uplink_bps},
		    _intb($r->{sum_down}), _intb($r->{sum_up}),
		    $r->{sample_count},
		);
	}
	_debug($cfg, "rollup minutes=" . scalar(@$rows)
	    . " obstr=$with from=$start to=$end open=$open");
	if (!@$rows && !$last) {
		return 0;
	}
	$dbh->do('UPDATE collector_state SET last_rolled_minute = ? WHERE id = 1',
	    undef, $open);
	return scalar @$rows;
}

sub roll_hours {
	my ($dbh, $now, $cfg) = @_;
	my $end = $now - ($now % 3600);
	return 0 if $end <= 0;
	my $start = $end - 2 * 86400;
	$start = 0 if $start < 0;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT (ts_minute - (ts_minute % 3600)) AS ts_hour,
		       AVG(avg_ping_drop_rate) AS avg_ping_drop_rate,
		       AVG(avg_ping_latency_ms) AS avg_ping_latency_ms,
		       MIN(min_ping_latency_ms) AS min_ping_latency_ms,
		       MAX(max_ping_latency_ms) AS max_ping_latency_ms,
		       AVG(avg_obstr_fraction) AS avg_obstr_fraction,
		       MAX(max_obstr_fraction) AS max_obstr_fraction,
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
		    ts_hour, avg_ping_drop_rate, avg_ping_latency_ms,
		    min_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, max_obstr_fraction, jitter_ms,
		    avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (ts_hour) DO UPDATE SET
		    avg_ping_drop_rate = excluded.avg_ping_drop_rate,
		    avg_ping_latency_ms = excluded.avg_ping_latency_ms,
		    min_ping_latency_ms = excluded.min_ping_latency_ms,
		    max_ping_latency_ms = excluded.max_ping_latency_ms,
		    avg_obstr_fraction = excluded.avg_obstr_fraction,
		    max_obstr_fraction = excluded.max_obstr_fraction,
		    jitter_ms = excluded.jitter_ms,
		    avg_downlink_bps = excluded.avg_downlink_bps,
		    avg_uplink_bps = excluded.avg_uplink_bps,
		    down_bytes = excluded.down_bytes,
		    up_bytes = excluded.up_bytes,
		    sample_count = excluded.sample_count
	});
	my $with = 0;
	for my $r (@$rows) {
		$with++ if defined $r->{avg_obstr_fraction};
		$sth->execute(
		    $r->{ts_hour}, $r->{avg_ping_drop_rate}, $r->{avg_ping_latency_ms},
		    $r->{min_ping_latency_ms}, $r->{max_ping_latency_ms},
		    $r->{avg_obstr_fraction}, $r->{max_obstr_fraction},
		    _spread($r->{min_ping_latency_ms}, $r->{max_ping_latency_ms}),
		    $r->{avg_downlink_bps}, $r->{avg_uplink_bps},
		    $r->{down_bytes}, $r->{up_bytes}, $r->{sample_count},
		);
	}
	_debug($cfg, "rollup hours=" . scalar(@$rows) . " obstr=$with from=$start to=$end");
	return scalar @$rows;
}

sub roll_days {
	my ($dbh, $now, $cfg) = @_;
	my $end = $now - ($now % 86400);
	return 0 if $end <= 0;
	my $start = $end - 40 * 86400;
	$start = 0 if $start < 0;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT (ts_hour - (ts_hour % 86400)) AS ts_day,
		       AVG(avg_ping_drop_rate) AS avg_ping_drop_rate,
		       AVG(avg_ping_latency_ms) AS avg_ping_latency_ms,
		       MIN(min_ping_latency_ms) AS min_ping_latency_ms,
		       MAX(max_ping_latency_ms) AS max_ping_latency_ms,
		       AVG(avg_obstr_fraction) AS avg_obstr_fraction,
		       MAX(max_obstr_fraction) AS max_obstr_fraction,
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
		    ts_day, avg_ping_drop_rate, avg_ping_latency_ms,
		    min_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, max_obstr_fraction, jitter_ms,
		    avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (ts_day) DO UPDATE SET
		    avg_ping_drop_rate = excluded.avg_ping_drop_rate,
		    avg_ping_latency_ms = excluded.avg_ping_latency_ms,
		    min_ping_latency_ms = excluded.min_ping_latency_ms,
		    max_ping_latency_ms = excluded.max_ping_latency_ms,
		    avg_obstr_fraction = excluded.avg_obstr_fraction,
		    max_obstr_fraction = excluded.max_obstr_fraction,
		    jitter_ms = excluded.jitter_ms,
		    avg_downlink_bps = excluded.avg_downlink_bps,
		    avg_uplink_bps = excluded.avg_uplink_bps,
		    down_bytes = excluded.down_bytes,
		    up_bytes = excluded.up_bytes,
		    sample_count = excluded.sample_count
	});
	my $with = 0;
	for my $r (@$rows) {
		$with++ if defined $r->{avg_obstr_fraction};
		$sth->execute(
		    $r->{ts_day}, $r->{avg_ping_drop_rate}, $r->{avg_ping_latency_ms},
		    $r->{min_ping_latency_ms}, $r->{max_ping_latency_ms},
		    $r->{avg_obstr_fraction}, $r->{max_obstr_fraction},
		    _spread($r->{min_ping_latency_ms}, $r->{max_ping_latency_ms}),
		    $r->{avg_downlink_bps}, $r->{avg_uplink_bps},
		    $r->{down_bytes}, $r->{up_bytes}, $r->{sample_count},
		);
	}
	_debug($cfg, "rollup days=" . scalar(@$rows) . " obstr=$with from=$start to=$end");
	return scalar @$rows;
}

# Rows strictly older than the window are compressed or deleted.
# A row one second newer than the cut stays.
# Obstruction is read from metrics before those rows are deleted.
# A row that already exists keeps its throughput and fills a null
# obstruction or jitter. It does not replace a value already stored.
sub retain {
	my ($dbh, $now, $raw_days, $hourly_days, $minutely_days, $cfg) = @_;
	my $raw_cut = $now - $raw_days * 86400;
	my $hour_cut = $now - $hourly_days * 86400;
	my $min_cut = $now - $minutely_days * 86400;

	$dbh->do(q{
		INSERT INTO metrics_hourly (
		    ts_hour, avg_ping_drop_rate, avg_ping_latency_ms,
		    min_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, max_obstr_fraction, jitter_ms,
		    avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		SELECT h.ts_hour,
		       h.avg_drop,
		       h.avg_lat,
		       h.min_lat,
		       h.max_lat,
		       m.avg_obstr,
		       m.max_obstr,
		       CASE WHEN h.min_lat IS NULL OR h.max_lat IS NULL THEN NULL
		            ELSE h.max_lat - h.min_lat END,
		       h.avg_down,
		       h.avg_up,
		       h.down_bytes,
		       h.up_bytes,
		       h.sample_count
		FROM (
			SELECT (ts - (ts % 3600)) AS ts_hour,
			       AVG(ping_drop_rate) AS avg_drop,
			       AVG(ping_latency_ms) AS avg_lat,
			       MIN(ping_latency_ms) AS min_lat,
			       MAX(ping_latency_ms) AS max_lat,
			       AVG(downlink_bps) AS avg_down,
			       AVG(uplink_bps) AS avg_up,
			       CAST(SUM(downlink_bps) AS BIGINT) / 8 AS down_bytes,
			       CAST(SUM(uplink_bps) AS BIGINT) / 8 AS up_bytes,
			       COUNT(*) AS sample_count
			FROM history_samples
			WHERE ts < ?
			GROUP BY (ts - (ts % 3600))
		) h
		LEFT JOIN (
			SELECT (ts - (ts % 3600)) AS ts_hour,
			       AVG(obstr_fraction) AS avg_obstr,
			       MAX(obstr_fraction) AS max_obstr
			FROM metrics
			WHERE ts < ? AND obstr_fraction IS NOT NULL
			GROUP BY (ts - (ts % 3600))
		) m ON m.ts_hour = h.ts_hour
		ON CONFLICT (ts_hour) DO UPDATE SET
		    min_ping_latency_ms = COALESCE(min_ping_latency_ms, excluded.min_ping_latency_ms),
		    avg_obstr_fraction = COALESCE(avg_obstr_fraction, excluded.avg_obstr_fraction),
		    max_obstr_fraction = COALESCE(max_obstr_fraction, excluded.max_obstr_fraction),
		    jitter_ms = COALESCE(jitter_ms, excluded.jitter_ms)
	}, undef, $raw_cut, $raw_cut);
	$dbh->do('DELETE FROM history_samples WHERE ts < ?', undef, $raw_cut);
	$dbh->do('DELETE FROM metrics WHERE ts < ?', undef, $raw_cut);

	$dbh->do(q{
		INSERT INTO metrics_daily (
		    ts_day, avg_ping_drop_rate, avg_ping_latency_ms,
		    min_ping_latency_ms, max_ping_latency_ms,
		    avg_obstr_fraction, max_obstr_fraction, jitter_ms,
		    avg_downlink_bps, avg_uplink_bps,
		    down_bytes, up_bytes, sample_count)
		SELECT (ts_hour - (ts_hour % 86400)),
		       AVG(avg_ping_drop_rate),
		       AVG(avg_ping_latency_ms),
		       MIN(min_ping_latency_ms),
		       MAX(max_ping_latency_ms),
		       AVG(avg_obstr_fraction),
		       MAX(max_obstr_fraction),
		       CASE
		           WHEN MIN(min_ping_latency_ms) IS NULL
		             OR MAX(max_ping_latency_ms) IS NULL THEN NULL
		           ELSE MAX(max_ping_latency_ms) - MIN(min_ping_latency_ms)
		       END,
		       AVG(avg_downlink_bps),
		       AVG(avg_uplink_bps),
		       SUM(down_bytes),
		       SUM(up_bytes),
		       SUM(sample_count)
		FROM metrics_hourly
		WHERE ts_hour < ?
		GROUP BY (ts_hour - (ts_hour % 86400))
		ON CONFLICT (ts_day) DO UPDATE SET
		    min_ping_latency_ms = COALESCE(min_ping_latency_ms, excluded.min_ping_latency_ms),
		    avg_obstr_fraction = COALESCE(avg_obstr_fraction, excluded.avg_obstr_fraction),
		    max_obstr_fraction = COALESCE(max_obstr_fraction, excluded.max_obstr_fraction),
		    jitter_ms = COALESCE(jitter_ms, excluded.jitter_ms)
	}, undef, $hour_cut);
	$dbh->do('DELETE FROM metrics_hourly WHERE ts_hour < ?', undef, $hour_cut);
	$dbh->do('DELETE FROM metrics_minutely WHERE ts_minute < ?', undef, $min_cut);
	$dbh->do('UPDATE collector_state SET last_retain_day = ? WHERE id = 1',
	    undef, $now - ($now % 86400));
	_debug($cfg, "rollup retain raw_cut=$raw_cut hour_cut=$hour_cut minute_cut=$min_cut");
	return;
}

1;
