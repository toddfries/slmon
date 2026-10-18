package SLMON::DB;

use strict;
use warnings;

use DBI qw(SQL_BLOB);
use Errno qw(EINTR);
use MIME::Base64 qw(encode_base64);
use POSIX ();
use SLMON ();
use SLMON::Auth;
use SLMON::Obstruction;
use SLMON::Rollup;

my %TSCOL = (
	history_samples  => 'ts',
	metrics          => 'ts',
	metrics_minutely => 'ts_minute',
	metrics_hourly   => 'ts_hour',
	metrics_daily    => 'ts_day',
	events           => 'ts',
	dish_info        => 'last_seen_ts',
	obstruction_map  => 'ts',
	weather          => 'ts',
	speedtests       => 'ts',
	alert_queue      => 'created_ts',
);

sub open_db {
	my ($cfg, %opt) = @_;
	if (($cfg->{db} // 'sqlite') eq 'pg') {
		require SLMON::DB::Pg;
		return SLMON::DB::Pg::connect($cfg, %opt);
	}
	require SLMON::DB::SQLite;
	return SLMON::DB::SQLite::connect($cfg, %opt);
}

sub _types {
	my ($name) = @_;
	if ($name eq 'pg') {
		require SLMON::DB::Pg;
		return SLMON::DB::Pg::types();
	}
	require SLMON::DB::SQLite;
	return SLMON::DB::SQLite::types();
}

sub ddl_for {
	my ($name) = @_;
	my $t = _types($name);
	my ($id, $big, $real, $blob, $int, $text) = @{$t}{qw(id big real blob int text)};
	return (
		qq{CREATE TABLE IF NOT EXISTS settings (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			admin_user $text NOT NULL,
			admin_pass_hash $text NOT NULL,
			session_secret $text NOT NULL
		)},
		qq{CREATE TABLE IF NOT EXISTS collector_state (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			run_id $big NOT NULL,
			last_counter $big,
			bootcount $int,
			last_rolled_minute $big,
			last_retain_day $big
		)},
		qq{CREATE TABLE IF NOT EXISTS history_samples (
			id $id,
			run_id $big NOT NULL,
			dish_counter $big NOT NULL,
			ts $big NOT NULL,
			ping_drop_rate $real,
			ping_latency_ms $real,
			downlink_bps $big,
			uplink_bps $big,
			UNIQUE (run_id, dish_counter)
		)},
		qq{CREATE INDEX IF NOT EXISTS idx_history_ts ON history_samples (ts)},
		qq{CREATE TABLE IF NOT EXISTS metrics (
			id $id,
			ts $big NOT NULL,
			ping_drop_rate $real,
			ping_latency_ms $real,
			obstr_fraction $real,
			obstr_valid_s $real,
			downlink_bps $big,
			uplink_bps $big,
			state $text,
			snr $real,
			uptime_s $big,
			seconds_to_first_nonempty_slot $real,
			currently_obstructed $int,
			obstruction_duration $real,
			obstruction_interval $real,
			direction_azimuth $real,
			direction_elevation $real,
			is_snr_above_noise_floor $int,
			gps_ready $int,
			gps_enabled $int,
			gps_sats $int,
			alerts_bitfield $big
		)},
		q{CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics (ts)},
		qq{CREATE TABLE IF NOT EXISTS dish_info (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			device_id $text,
			hardware_version $text,
			software_version $text,
			country_code $text,
			bootcount $int,
			alerts_bitfield $big,
			last_seen_ts $big
		)},
		qq{CREATE TABLE IF NOT EXISTS obstruction_map (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			ts $big,
			num_rows $int,
			num_cols $int,
			snr $blob
		)},
		qq{CREATE TABLE IF NOT EXISTS events (
			id $id,
			ts $big NOT NULL,
			type $text NOT NULL,
			duration_s $real,
			details $text
		)},
		q{CREATE INDEX IF NOT EXISTS idx_events_ts ON events (ts)},
		q{CREATE INDEX IF NOT EXISTS idx_events_type ON events (type)},
		qq{CREATE TABLE IF NOT EXISTS metrics_minutely (
			id $id,
			ts_minute $big NOT NULL UNIQUE,
			avg_ping_drop_rate $real,
			avg_ping_latency_ms $real,
			min_ping_latency_ms $real,
			max_ping_latency_ms $real,
			avg_obstr_fraction $real,
			max_obstr_fraction $real,
			avg_downlink_bps $real,
			min_downlink_bps $real,
			max_downlink_bps $real,
			avg_uplink_bps $real,
			min_uplink_bps $real,
			max_uplink_bps $real,
			down_bytes $big,
			up_bytes $big,
			sample_count $big
		)},
		qq{CREATE TABLE IF NOT EXISTS metrics_hourly (
			id $id,
			ts_hour $big NOT NULL UNIQUE,
			avg_ping_drop_rate $real,
			avg_ping_latency_ms $real,
			max_ping_latency_ms $real,
			avg_obstr_fraction $real,
			avg_downlink_bps $real,
			avg_uplink_bps $real,
			down_bytes $big,
			up_bytes $big,
			sample_count $big
		)},
		qq{CREATE TABLE IF NOT EXISTS metrics_daily (
			id $id,
			ts_day $big NOT NULL UNIQUE,
			avg_ping_drop_rate $real,
			avg_ping_latency_ms $real,
			max_ping_latency_ms $real,
			avg_obstr_fraction $real,
			avg_downlink_bps $real,
			avg_uplink_bps $real,
			down_bytes $big,
			up_bytes $big,
			sample_count $big
		)},
		qq{CREATE TABLE IF NOT EXISTS weather (
			id $id,
			ts $big NOT NULL,
			temp_c $real,
			wind_kmh $real,
			wmo_code $int,
			precipitation_mm $real,
			visibility_m $int,
			humidity $real,
			warning $text
		)},
		q{CREATE INDEX IF NOT EXISTS idx_weather_ts ON weather (ts)},
		qq{CREATE TABLE IF NOT EXISTS speedtests (
			id $id,
			ts $big NOT NULL,
			download_mbit $real,
			upload_mbit $real,
			latency_ms $real,
			jitter_ms $real,
			server $text
		)},
		qq{CREATE TABLE IF NOT EXISTS alert_queue (
			id $id,
			created_ts $big NOT NULL,
			payload_json $text NOT NULL,
			attempts $int NOT NULL DEFAULT 0,
			last_attempt_ts $big
		)},
	);
}

sub init_schema {
	my ($dbh) = @_;
	my $name = $dbh->{private_slmon_driver} || 'sqlite';
	for my $sql (ddl_for($name)) {
		$dbh->do($sql);
	}
	$dbh->do(q{
		INSERT INTO collector_state
		    (id, run_id, last_counter, bootcount, last_rolled_minute, last_retain_day)
		VALUES (1, 1, NULL, NULL, 0, 0)
		ON CONFLICT (id) DO NOTHING
	});
	return;
}

sub settings {
	my ($dbh) = @_;
	my $row = $dbh->selectrow_hashref(
	    'SELECT admin_user, admin_pass_hash, session_secret FROM settings WHERE id = 1');
	return $row;
}

sub settings_put {
	my ($dbh, $user, $hash, $secret) = @_;
	$dbh->do(q{
		INSERT INTO settings (id, admin_user, admin_pass_hash, session_secret)
		VALUES (1, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET
		    admin_user = excluded.admin_user,
		    admin_pass_hash = excluded.admin_pass_hash,
		    session_secret = excluded.session_secret
	}, undef, $user, $hash, $secret);
	return;
}

sub check_login {
	my ($dbh, $user, $pw) = @_;
	my $row = settings($dbh);
	return 0 if !$row;
	return 0 if !defined $user || $user ne $row->{admin_user};
	return SLMON::Auth::verify_password($pw, $row->{admin_pass_hash});
}

sub ingest_history {
	my ($dbh, $msg) = @_;
	my $boot = $msg->{bootcount};
	my $samples = $msg->{samples} || [];
	# current is the newest counter in this poll. Chunks of an overlapping
	# ring start behind last_counter; only a tip that moved backwards, or a
	# bootcount change, starts a run. Without current, the batch maximum is
	# the tip.
	my $tip = $msg->{current};
	if (!defined $tip) {
		for my $s (@$samples) {
			my $c = $s->{counter};
			$c = $s->{dish_counter} if !defined $c;
			next if !defined $c;
			$c = int($c);
			$tip = $c if !defined $tip || $c > $tip;
		}
	} else {
		$tip = int($tip);
	}
	$dbh->begin_work;
	eval {
		my ($run, $last, $curboot) = $dbh->selectrow_array(
		    'SELECT run_id, last_counter, bootcount FROM collector_state WHERE id = 1');
		$run //= 1;
		if (defined $boot && defined $curboot && int($boot) != int($curboot)) {
			$run++;
			$last = undef;
		} elsif (defined $last && defined $tip && $tip < $last) {
			$run++;
			$last = undef;
		}
		my $sth = $dbh->prepare(q{
			INSERT INTO history_samples (
			    run_id, dish_counter, ts, ping_drop_rate, ping_latency_ms,
			    downlink_bps, uplink_bps)
			VALUES (?,?,?,?,?,?,?)
			ON CONFLICT (run_id, dish_counter) DO NOTHING
		});
		for my $s (@$samples) {
			my $c = $s->{counter};
			$c = $s->{dish_counter} if !defined $c;
			die "history sample missing counter\n" if !defined $c;
			$c = int($c);
			next if defined $last && $c <= $last;
			my $drop = $s->{drop};
			$drop = $s->{ping_drop_rate} if !defined $drop;
			my $lat = $s->{latency};
			$lat = $s->{ping_latency_ms} if !defined $lat;
			$lat = undef if defined $drop && $drop >= 1;
			my $down = $s->{down_bps};
			$down = $s->{downlink_bps} if !defined $down;
			my $up = $s->{up_bps};
			$up = $s->{uplink_bps} if !defined $up;
			$sth->execute($run, $c, int($s->{ts}), $drop, $lat,
			    defined $down ? int($down) : undef,
			    defined $up ? int($up) : undef);
			$last = $c if !defined $last || $c > $last;
		}
		$dbh->do(q{
			UPDATE collector_state
			SET run_id = ?, last_counter = ?, bootcount = ?
			WHERE id = 1
		}, undef, $run, $last, defined $boot ? int($boot) : $curboot);
		$dbh->commit;
	};
	if ($@) {
		my $err = $@;
		eval { $dbh->rollback };
		die $err;
	}
	return;
}

sub insert_metric {
	my ($dbh, $row) = @_;
	$dbh->do(q{
		INSERT INTO metrics (
		    ts, ping_drop_rate, ping_latency_ms, obstr_fraction, obstr_valid_s,
		    downlink_bps, uplink_bps, state, snr, uptime_s,
		    seconds_to_first_nonempty_slot, currently_obstructed,
		    obstruction_duration, obstruction_interval,
		    direction_azimuth, direction_elevation, is_snr_above_noise_floor,
		    gps_ready, gps_enabled, gps_sats, alerts_bitfield)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
	}, undef,
	    $row->{ts}, $row->{ping_drop_rate}, $row->{ping_latency_ms},
	    $row->{obstr_fraction}, $row->{obstr_valid_s},
	    $row->{downlink_bps}, $row->{uplink_bps}, $row->{state}, $row->{snr},
	    $row->{uptime_s}, $row->{seconds_to_first_nonempty_slot},
	    $row->{currently_obstructed}, $row->{obstruction_duration},
	    $row->{obstruction_interval}, $row->{direction_azimuth},
	    $row->{direction_elevation}, $row->{is_snr_above_noise_floor},
	    $row->{gps_ready}, $row->{gps_enabled}, $row->{gps_sats},
	    $row->{alerts_bitfield});
	return;
}

sub upsert_dish_info {
	my ($dbh, $row) = @_;
	$dbh->do(q{
		INSERT INTO dish_info (
		    id, device_id, hardware_version, software_version, country_code,
		    bootcount, alerts_bitfield, last_seen_ts)
		VALUES (1,?,?,?,?,?,?,?)
		ON CONFLICT (id) DO UPDATE SET
		    device_id = excluded.device_id,
		    hardware_version = excluded.hardware_version,
		    software_version = excluded.software_version,
		    country_code = excluded.country_code,
		    bootcount = excluded.bootcount,
		    alerts_bitfield = excluded.alerts_bitfield,
		    last_seen_ts = excluded.last_seen_ts
	}, undef,
	    $row->{device_id}, $row->{hardware_version}, $row->{software_version},
	    $row->{country_code}, $row->{bootcount}, $row->{alerts_bitfield},
	    $row->{last_seen_ts});
	return;
}

sub upsert_obstruction {
	my ($dbh, $row) = @_;
	my $sth = $dbh->prepare(q{
		INSERT INTO obstruction_map (id, ts, num_rows, num_cols, snr)
		VALUES (1, ?, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET
		    ts = excluded.ts,
		    num_rows = excluded.num_rows,
		    num_cols = excluded.num_cols,
		    snr = excluded.snr
	});
	$sth->bind_param(1, $row->{ts});
	$sth->bind_param(2, $row->{num_rows});
	$sth->bind_param(3, $row->{num_cols});
	if (($dbh->{private_slmon_driver} || '') eq 'pg') {
		require DBD::Pg;
		$sth->bind_param(4, $row->{snr}, { pg_type => DBD::Pg::PG_BYTEA() });
	} else {
		$sth->bind_param(4, $row->{snr}, SQL_BLOB);
	}
	$sth->execute;
	return;
}

sub insert_event {
	my ($dbh, $ev) = @_;
	$dbh->do(q{
		INSERT INTO events (ts, type, duration_s, details)
		VALUES (?,?,?,?)
	}, undef, $ev->{ts}, $ev->{type}, $ev->{duration_s}, $ev->{details});
	return;
}

sub insert_weather {
	my ($dbh, $row) = @_;
	$dbh->do(q{
		INSERT INTO weather (
		    ts, temp_c, wind_kmh, wmo_code, precipitation_mm,
		    visibility_m, humidity, warning)
		VALUES (?,?,?,?,?,?,?,?)
	}, undef,
	    $row->{ts}, $row->{temp_c}, $row->{wind_kmh}, $row->{wmo_code},
	    $row->{precipitation_mm}, $row->{visibility_m}, $row->{humidity},
	    $row->{warning});
	return;
}

sub normalize_query {
	my ($q) = @_;
	$q = {} if !$q;
	my $op = $q->{op} // '';
	die "unknown query op\n" if $op ne 'latest' && $op ne 'raw';
	my $table = $q->{table} // '';
	die "unknown table\n" if !exists $TSCOL{$table};
	my $limit = $q->{limit};
	if (!defined $limit || $limit eq '') {
		$limit = 5000;
	}
	die "limit must be an integer\n" if $limit !~ /\A[0-9]+\z/;
	$limit = int($limit);
	$limit = 1 if $limit < 1;
	$limit = 50000 if $limit > 50000;
	my $order = lc($q->{order} // 'asc');
	die "order must be asc or desc\n" if $order ne 'asc' && $order ne 'desc';
	my $from = $q->{from};
	my $to = $q->{to};
	$from = undef if defined $from && $from eq '';
	$to = undef if defined $to && $to eq '';
	for my $v ($from, $to) {
		next if !defined $v;
		die "time bound must be an integer\n" if $v !~ /\A-?[0-9]+\z/;
	}
	return {
		op    => $op,
		table => $table,
		tscol => $TSCOL{$table},
		limit => $limit,
		order => $order,
		from  => defined $from ? int($from) : undef,
		to    => defined $to ? int($to) : undef,
	};
}

sub _shape_rows {
	my ($table, $rows) = @_;
	for my $row (@$rows) {
		for my $k (keys %$row) {
			next if !defined $row->{$k};
			if ($k =~ /\A(?:id|ts|run_id|dish_counter|downlink_bps|uplink_bps|down_bytes|up_bytes|sample_count|uptime_s|bootcount|alerts_bitfield|ts_minute|ts_hour|ts_day|last_seen_ts|num_rows|num_cols|wmo_code|visibility_m|gps_sats|attempts|created_ts|last_attempt_ts|currently_obstructed|is_snr_above_noise_floor|gps_ready|gps_enabled)\z/) {
				$row->{$k} = 0 + $row->{$k} if $row->{$k} =~ /\A-?\d+(?:\.\d+)?\z/;
			}
		}
		if ($table eq 'obstruction_map' && defined $row->{snr}) {
			$row->{snr_b64} = encode_base64($row->{snr}, '');
			delete $row->{snr};
		}
	}
	return $rows;
}

sub query_rows {
	my ($dbh, $q) = @_;
	my $n = normalize_query($q);
	if ($n->{op} eq 'latest') {
		my $sql = "SELECT * FROM $n->{table} ORDER BY $n->{tscol} DESC LIMIT 1";
		my $rows = $dbh->selectall_arrayref($sql, { Slice => {} });
		return _shape_rows($n->{table}, $rows);
	}
	my @where;
	my @bind;
	if (defined $n->{from}) {
		push @where, "$n->{tscol} >= ?";
		push @bind, $n->{from};
	}
	if (defined $n->{to}) {
		push @where, "$n->{tscol} <= ?";
		push @bind, $n->{to};
	}
	my $sql = "SELECT * FROM $n->{table}";
	$sql .= ' WHERE ' . join(' AND ', @where) if @where;
	$sql .= " ORDER BY $n->{tscol} " . ($n->{order} eq 'desc' ? 'DESC' : 'ASC');
	$sql .= ' LIMIT ?';
	push @bind, $n->{limit};
	my $rows = $dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
	return _shape_rows($n->{table}, $rows);
}

sub parse_obstruction {
	my ($data) = @_;
	return undef if !defined $data || length($data) < 20;
	my ($ts, $rows, $cols, $n) = unpack('Q< V V V', $data);
	my $need = 20 + $n * 4;
	return undef if length($data) < $need;
	return {
		ts       => $ts,
		num_rows => $rows,
		num_cols => $cols,
		snr      => substr($data, 20, $n * 4),
	};
}

sub _pledge_db {
	my ($cfg) = @_;
	require OpenBSD::Pledge;
	require OpenBSD::Unveil;
	my $dir = $cfg->{state_dir} || '.';
	if (($cfg->{db} // '') eq 'sqlite') {
		OpenBSD::Unveil::unveil($dir, 'rwc')
		    or die "slmon: db unveil: $!\n";
	}
	if (($cfg->{db} // '') eq 'pg') {
		my $sock = $cfg->{pg_host};
		if (defined $sock && $sock ne '' && $sock =~ m{\A/}) {
			OpenBSD::Unveil::unveil($sock, 'rw')
			    or die "slmon: db unveil pg socket: $!\n";
		}
		OpenBSD::Unveil::unveil('/tmp', 'rw')
		    or die "slmon: db unveil /tmp: $!\n";
	}
	OpenBSD::Unveil::unveil()
	    or die "slmon: db unveil lock: $!\n";
	my @p = qw(rpath wpath cpath flock recvfd);
	push @p, 'unix' if ($cfg->{db} // '') eq 'pg';
	OpenBSD::Pledge::pledge(@p)
	    or die "slmon: db pledge: $!\n";
	return;
}

sub _send_rows {
	my ($imsg, $rows) = @_;
	my @chunk;
	my $bytes = 2;
	for my $row (@$rows) {
		my $one = SLMON::json_encode($row);
		if (@chunk && $bytes + length($one) + 1 > 200000) {
			$imsg->send(SLMON::IMSG_ROWS, SLMON::json_encode({ rows => \@chunk }));
			@chunk = ();
			$bytes = 2;
		}
		push @chunk, $row;
		$bytes += length($one) + 1;
	}
	$imsg->send(SLMON::IMSG_ROWS, SLMON::json_encode({ rows => \@chunk })) if @chunk || !@$rows;
	$imsg->send(SLMON::IMSG_QUERY_DONE, SLMON::json_encode({}));
	return;
}

sub _dispatch_peer {
	my ($dbh, $imsg, $msg, $obs, $cfg, $roll) = @_;
	my $type = $msg->{type};
	if ($type == SLMON::IMSG_STATUS) {
		my $row = SLMON::json_decode($msg->{data});
		insert_metric($dbh, $row);
		my $ev = SLMON::Obstruction::observe($obs, $row->{obstr_fraction}, $row->{ts});
		insert_event($dbh, $ev) if $ev;
	} elsif ($type == SLMON::IMSG_HISTORY) {
		my $doc = SLMON::json_decode($msg->{data});
		ingest_history($dbh, $doc);
		SLMON::Rollup::roll_minutes($dbh, time);
		SLMON::Rollup::roll_hours($dbh, time);
		SLMON::Rollup::roll_days($dbh, time);
		$roll->{last} = time;
	} elsif ($type == SLMON::IMSG_DISH_INFO) {
		upsert_dish_info($dbh, SLMON::json_decode($msg->{data}));
	} elsif ($type == SLMON::IMSG_OBSTRUCTION) {
		my $row = parse_obstruction($msg->{data});
		upsert_obstruction($dbh, $row) if $row;
	} elsif ($type == SLMON::IMSG_EVENT) {
		insert_event($dbh, SLMON::json_decode($msg->{data}));
	} elsif ($type == SLMON::IMSG_WEATHER) {
		insert_weather($dbh, SLMON::json_decode($msg->{data}));
	} elsif ($type == SLMON::IMSG_QUERY) {
		my $q = SLMON::json_decode($msg->{data});
		my $rows = eval { query_rows($dbh, $q) };
		if ($@) {
			$imsg->send(SLMON::IMSG_QUERY_DONE,
			    SLMON::json_encode({ error => "$@" }));
		} else {
			_send_rows($imsg, $rows);
		}
	} elsif ($type == SLMON::IMSG_LOGIN) {
		my $q = SLMON::json_decode($msg->{data});
		my $ok = eval { check_login($dbh, $q->{user}, $q->{password}) };
		$ok = 0 if $@;
		$imsg->send(SLMON::IMSG_LOGIN_RESULT,
		    SLMON::json_encode({ ok => $ok ? 1 : 0 }));
	}
	return;
}

sub _maybe_roll {
	my ($dbh, $cfg, $roll) = @_;
	my $now = time;
	my $every = $cfg->{rollup_interval_s} || 60;
	return if $now - ($roll->{last} || 0) < $every;
	$roll->{last} = $now;
	SLMON::Rollup::roll_minutes($dbh, $now);
	SLMON::Rollup::roll_hours($dbh, $now);
	SLMON::Rollup::roll_days($dbh, $now);
	if ($now - ($roll->{retain} || 0) >= 86400) {
		SLMON::Rollup::retain($dbh, $now,
		    $cfg->{raw_retention_days},
		    $cfg->{hourly_rollup_days},
		    $cfg->{minutely_retention_days});
		$roll->{retain} = $now;
	}
	return;
}

sub _on_attach {
	my ($peers, $msg, $ctl, $dbh) = @_;
	my $doc = SLMON::json_decode($msg->{data}) || {};
	my $name = $doc->{peer} || '';
	die "attach missing peer\n" if $name eq '';
	die "attach missing fd\n" if !defined $msg->{fd} || $msg->{fd} < 0;
	if ($peers->{$name}) {
		POSIX::close($peers->{$name}->fd);
		delete $peers->{$name};
	}
	$peers->{$name} = SLMON::Imsg->open($msg->{fd});
	if ($name eq 'http') {
		my $s = settings($dbh);
		$peers->{$name}->send(SLMON::IMSG_CONFIG, SLMON::json_encode({
			session_secret => $s->{session_secret},
			admin_user     => $s->{admin_user},
		}));
	}
	$ctl->send(SLMON::IMSG_ACK, SLMON::json_encode({ peer => $name }));
	return;
}

sub child {
	my ($sock, $cfg) = @_;
	SLMON::proc_title('db');
	require SLMON::Imsg;
	$SIG{TERM} = sub { exit 0 };
	$SIG{PIPE} = 'IGNORE';
	my $dbh = open_db($cfg);
	init_schema($dbh);
	_pledge_db($cfg);
	my $ctl = SLMON::Imsg->open(fileno($sock));
	my $have = settings($dbh);
	if ($have) {
		$ctl->send(SLMON::IMSG_READY, '{}');
	} else {
		$ctl->send(SLMON::IMSG_NEED_INIT, '{}');
	}
	my %peers;
	my $obs = {};
	my $roll = { last => 0, retain => time };
	my $ready = $have ? 1 : 0;
	while (1) {
		my $rin = '';
		vec($rin, $ctl->fd, 1) = 1;
		for my $p (values %peers) {
			vec($rin, $p->fd, 1) = 1;
		}
		my $n = select($rin, undef, undef, 1);
		if (!defined $n) {
			next if $! == EINTR;
			die "select: $!\n";
		}
		if (vec($rin, $ctl->fd, 1)) {
			my $r = $ctl->read_more;
			exit 0 if defined $r && $r == 0;
			while (my $msg = $ctl->get) {
				if ($msg->{type} == SLMON::IMSG_SHUTDOWN) {
					exit 0;
				}
				eval {
					if ($msg->{type} == SLMON::IMSG_SET_AUTH) {
						my $doc = SLMON::json_decode($msg->{data});
						settings_put($dbh, $doc->{user}, $doc->{pass_hash},
						    $doc->{session_secret});
						$ready = 1;
						$ctl->send(SLMON::IMSG_READY, '{}');
					} elsif ($msg->{type} == SLMON::IMSG_ATTACH) {
						die "not ready\n" if !$ready;
						_on_attach(\%peers, $msg, $ctl, $dbh);
					}
				};
				warn "slmon: db ctl: $@" if $@;
			}
		}
		for my $name (keys %peers) {
			my $p = $peers{$name} or next;
			next if !vec($rin, $p->fd, 1);
			my $r = $p->read_more;
			if (defined $r && $r == 0) {
				POSIX::close($p->fd);
				delete $peers{$name};
				next;
			}
			while (my $msg = $p->get) {
				eval { _dispatch_peer($dbh, $p, $msg, $obs, $cfg, $roll) };
				warn "slmon: db peer $name: $@" if $@;
			}
		}
		eval { _maybe_roll($dbh, $cfg, $roll) };
		warn "slmon: db rollup: $@" if $@;
	}
}

1;
