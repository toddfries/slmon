package SLMON::Top;

use strict;
use warnings;

use MIME::Base64 qw(decode_base64);
use POSIX qw(strftime);
use SLMON ();
use SLMON::DB;
use SLMON::Dash;
use SLMON::StatusMap;

my @MARK = (' ', '.', ':', '-', '=', '+', '*', '#');

sub load {
	my ($dbh, $cfg, $range, $now) = @_;
	$now //= time;
	$range = SLMON::Dash::range_name($range);
	my $sec = SLMON::Dash::range_seconds($range);
	my $from = defined $sec ? $now - $sec : undef;
	my $table = SLMON::Dash::series_table($range);
	my $series = _rows($dbh, $table, $from, $now, 20000, 'asc');
	if (SLMON::Dash::hourly_tail($range)) {
		my $hourly = _rows($dbh, 'metrics_hourly', $from, $now, 20000, 'asc');
		$series = SLMON::Dash::merge_unrolled($series, $hourly);
	}
	my $obstruction = $series;
	if (!SLMON::Dash::tier_has_obstr($series)) {
		$obstruction = _rows($dbh, 'metrics', $from, $now, 20000, 'asc');
	}
	my $latest = _rows($dbh, 'metrics', undef, undef, 1, 'desc');
	my $info = _rows($dbh, 'dish_info', undef, undef, 1, 'desc');
	my $events = _rows($dbh, 'events', $from, $now, 30, 'desc');
	my $look = defined $from ? $from - 90 * 86400 : undef;
	my $sla_events = _rows($dbh, 'events', $look, $now, 50000, 'desc');
	my $origin;
	if (!defined $from) {
		for my $row (@$series) {
			my $ts = $row->{ts} // $row->{ts_minute}
			    // $row->{ts_hour} // $row->{ts_day};
			next if !defined $ts || $ts !~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;
			$ts = int($ts);
			$origin = $ts if !defined $origin || $ts < $origin;
		}
	}
	my $hour = _rows($dbh, 'history_samples', $now - 3600, $now, 5000, 'asc');
	my $map = _rows($dbh, 'obstruction_map', undef, undef, 1, 'desc');
	my $weather;
	if (SLMON::Dash::weather_on($cfg)) {
		$weather = _rows($dbh, 'weather', $from, $now, 5000, 'asc');
	}
	my ($hist) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
	my $settings = eval { SLMON::DB::settings($dbh) };
	my $port = _http_port($cfg);
	return {
		series      => $series,
		obstruction => $obstruction,
		latest      => $latest->[0] || {},
		info        => $info->[0] || {},
		events      => $events,
		sla_events  => $sla_events,
		sla         => SLMON::Dash::sla($sla_events, $from, $now, $origin),
		map         => $map->[0],
		hour        => $hour,
		weather     => $weather,
		window_from => $from,
		window_to   => $now,
		range       => $range,
		now         => $now,
		cfg         => $cfg,
		view_meta   => SLMON::Dash::view_from($cfg),
		history_n   => $hist // 0,
		initialized => $settings ? 'yes' : 'no',
		http_port   => $port,
	};
}

sub _rows {
	my ($dbh, $table, $from, $to, $limit, $order) = @_;
	if (!defined $from && !defined $to) {
		return SLMON::DB::query_rows($dbh, {
			op => 'latest', table => $table,
		});
	}
	return SLMON::DB::query_rows($dbh, {
		op => 'raw', table => $table,
		from => $from, to => $to,
		limit => $limit, order => $order,
	});
}

sub _http_port {
	my ($cfg) = @_;
	my $dir = $cfg->{state_dir} // '';
	return '' if $dir eq '';
	my $path = "$dir/http.port";
	open my $fh, '<', $path or return '';
	my $port = <$fh> // '';
	close $fh;
	chomp $port;
	return $port;
}

# 1 keeps running. 0 leaves.
sub apply_key {
	my ($state, $key) = @_;
	return 0 if !defined $key || $key eq 'q' || $key eq 'Q';
	my %view = (
		o => 'overview', l => 'quality', t => 'throughput',
		d => 'dish', h => 'history', c => 'config',
	);
	my %range = (
		H => '24h', W => '7d', M => '30d', Y => '365d', E => 'ever',
	);
	if (exists $view{$key}) {
		$state->{view} = $view{$key};
	} elsif (exists $range{$key}) {
		$state->{range} = $range{$key};
	} elsif ($key eq '+') {
		$state->{interval}++;
	} elsif ($key eq '-') {
		$state->{interval}-- if ($state->{interval} // 1) > 1;
	}
	return 1;
}

sub frame {
	my ($page, %opt) = @_;
	$page = {} if ref $page ne 'HASH';
	my $width = $opt{width} || 80;
	$width = 20 if $width < 20;
	my $view = $opt{view} || 'overview';
	my $range = SLMON::Dash::range_name($opt{range} || $page->{range});
	my $interval = $opt{interval} || 3;
	my $now = $opt{now} // $page->{now} // time;
	my $latest = ref $page->{latest} eq 'HASH' ? $page->{latest} : {};
	my $ts = _n($latest->{ts});
	my $clock = defined $ts ? strftime('%H:%M:%S', localtime($ts)) : 'n/a';
	my $stale = (defined $ts && ($now - $ts) > 120) ? ' stale' : '';
	my @foot = (
		_wrap($width,
		    'o overview  l quality  t throughput  d dish  h history  c config'),
		_wrap($width,
		    'H 24h  W 7d  M 30d  Y 365d  E ever    + - interval    q quit'),
	);
	my $map_rows;
	if ($view eq 'dish' && $opt{height}) {
		# Header, three dish lines, the map caption, and the footer.
		my $used = 5 + @foot;
		$map_rows = $opt{height} - $used;
		$map_rows = 1 if $map_rows < 1;
	}
	my @lines;
	push @lines, _fit($width, join('   ',
	    'slctl top', $view, $range, "every ${interval}s", "sample $clock")
	    . $stale);
	if ($view eq 'throughput') {
		push @lines, _throughput($page, $width, $range, $now,
		    $opt{height}, scalar @foot);
	} elsif ($view eq 'quality') {
		push @lines, _quality($page, $width, $range, $now,
		    $opt{height}, scalar @foot);
	} elsif ($view eq 'dish') {
		push @lines, _dish($page, $width, $map_rows);
	} elsif ($view eq 'history') {
		push @lines, _history($page, $width, $now, $opt{height});
	} elsif ($view eq 'config') {
		push @lines, _config($page, $width);
	} else {
		push @lines, _overview($page, $width, $now,
		    $opt{height}, scalar @foot);
	}
	my $height = $opt{height} || 0;
	if ($height > @foot + 1 && @lines + @foot > $height) {
		my $room = $height - @foot - 1;
		my @mid = @lines[1 .. $#lines];
		if (@mid > $room) {
			if ($room <= 1) {
				@mid = ('...');
			} else {
				@mid = (@mid[0 .. $room - 2], '...');
			}
		}
		@lines = ($lines[0], @mid);
	}
	push @lines, @foot;
	my $text = join("\n", @lines) . "\n";
	$text =~ s/device_id//g;
	return $text;
}

sub _overview {
	my ($page, $width, $now, $height, $foot_n) = @_;
	my $latest = $page->{latest} || {};
	my @out = _stats($latest, $width);
	my $open_src = ref $page->{sla_events} eq 'ARRAY'
	    ? $page->{sla_events} : $page->{events};
	my @open = _open_lines($open_src, $now, $width);
	push @out, @open;
	push @out, _charts_or_note($width, 'last hour', $now - 3600, $now, [
		_hour_pts($page->{hour}, 'downlink_bps'),
		_hour_pts($page->{hour}, 'uplink_bps'),
	], [
		['downlink, last hour', 'down'],
		['uplink, last hour', 'up'],
	], _chart_budget($height, $foot_n, 2 + @open));
	return @out;
}

sub _throughput {
	my ($page, $width, $range, $now, $height, $foot_n) = @_;
	my $vol = SLMON::Dash::volume_bytes($page->{series});
	my @out = _stats($page->{latest} || {}, $width);
	push @out, _fit($width, 'bytes down  ' . SLMON::Dash::fmt_bytes($vol->{down})
	    . '    bytes up  ' . SLMON::Dash::fmt_bytes($vol->{up})
	    . '    bytes total  ' . SLMON::Dash::fmt_bytes($vol->{total}));
	my $pts = SLMON::Dash::points($page->{series});
	my $from = $page->{window_from};
	$from = $pts->[0]{t} if !defined $from && @$pts;
	$from = $now - 1 if !defined $from;
	push @out, _charts_or_note($width, $range, $from, $now, [
		_keyed($pts, 'down'),
		_keyed($pts, 'up'),
	], [
		["downlink, $range", 'down'],
		["uplink, $range", 'up'],
	], _chart_budget($height, $foot_n, 3));
	return @out;
}

sub _quality {
	my ($page, $width, $range, $now, $height, $foot_n) = @_;
	my $latest = $page->{latest} || {};
	my @out = _stats($latest, $width);
	my $weather = 0;
	if (SLMON::Dash::weather_on($page->{cfg})) {
		$weather = 1;
		push @out, _fit($width, 'weather  ' . _weather_word($page->{weather}));
	}
	my $pts = SLMON::Dash::points($page->{obstruction} || $page->{series});
	my $from = $page->{window_from};
	$from = $pts->[0]{t} if !defined $from && @$pts;
	$from = $now - 1 if !defined $from;
	push @out, _charts_or_note($width, $range, $from, $now, [
		_scaled($pts, 'lat', 1),
		_scaled($pts, 'drop', 100),
		_scaled($pts, 'obstr', 100),
	], [
		["latency, $range", 'ms'],
		["loss, $range", '%'],
		["obstruction, $range", '%'],
	], _chart_budget($height, $foot_n, 2 + $weather));
	return @out;
}

sub _dish {
	my ($page, $width, $map_rows) = @_;
	my $latest = $page->{latest} || {};
	my $info = $page->{info} || {};
	my $ob = _n($latest->{obstr_fraction});
	my $cur = $latest->{currently_obstructed};
	my $cur_s = defined $cur && $cur ne '' ? ($cur ? 'yes' : 'no') : 'n/a';
	my @out = (_fit($width, 'obstruction  '
	    . (defined $ob ? sprintf('%.3f%%', $ob * 100) : 'n/a')
	    . '    currently  ' . $cur_s
	    . '    duration  ' . SLMON::Dash::fmt_span($latest->{obstruction_duration})
	    . '    interval  ' . SLMON::Dash::fmt_span($latest->{obstruction_interval})));
	my @id;
	push @id, $info->{hardware_version} if defined $info->{hardware_version} && $info->{hardware_version} ne '';
	push @id, $info->{software_version} if defined $info->{software_version} && $info->{software_version} ne '';
	push @id, 'boot ' . int($info->{bootcount}) if defined _n($info->{bootcount});
	my $az = _n($latest->{direction_azimuth});
	my $el = _n($latest->{direction_elevation});
	push @id, sprintf('az %.1f el %.1f', $az, $el) if defined $az && defined $el;
	my $snr = _n($latest->{snr});
	push @id, sprintf('snr %.2f', $snr) if defined $snr;
	my $sats = _n($latest->{gps_sats});
	push @id, int($sats) . ' gps' if defined $sats;
	push @out, _fit($width, @id ? join('  ', @id) : 'dish  n/a');
	my @alerts = SLMON::StatusMap::alert_names($latest->{alerts_bitfield});
	push @out, _fit($width, @alerts ? 'alerts  ' . join(', ', @alerts) : 'alerts  none');
	push @out, _map_lines($page->{map}, $az, $el, $width, $map_rows);
	return @out;
}

sub _history {
	my ($page, $width, $now, $height) = @_;
	my $sla = ref $page->{sla} eq 'HASH' ? $page->{sla} : {};
	my $busiest = defined $sla->{busiest} ? sprintf('%02d', $sla->{busiest}) : 'n/a';
	my @out = (_fit($width, 'uptime  ' . SLMON::Dash::fmt_ratio($sla->{uptime})
	    . '    longest  ' . SLMON::Dash::fmt_span($sla->{longest_s})
	    . '    between  ' . SLMON::Dash::fmt_span($sla->{mtbo_s})
	    . '    busiest  ' . $busiest));
	my $hours = SLMON::Dash::fmt_hours($sla->{hours});
	push @out, _fit($width, $hours eq '' ? 'hours  none' : "hours  $hours");
	push @out, _fit($width, _calendar($page, $width, $now));
	my @ev = @{ $page->{events} || [] };
	my $budget = 12;
	if ($height && $height > 6) {
		$budget = $height - 6;
		$budget = 1 if $budget < 1;
	}
	if (!@ev) {
		push @out, _fit($width, 'events  none');
	} else {
		my $shown = 0;
		for my $row (@ev) {
			last if $shown >= $budget;
			my $ts = $row->{ts} // '';
			my $type = $row->{type} // '';
			next if $type eq 'ping_ok';
			my $details = $row->{details} // '';
			push @out, _fit($width, "$ts $type $details");
			$shown++;
		}
		push @out, _fit($width, 'events  none') if !$shown;
	}
	return @out;
}

sub _config {
	my ($page, $width) = @_;
	my $cfg = $page->{cfg} || {};
	my $meta = $page->{view_meta} || SLMON::Dash::view_from($cfg);
	my @out = (
		_fit($width, 'initialized  ' . ($page->{initialized} // 'no')),
		_fit($width, 'db  ' . ($meta->{db} // '')),
		_fit($width, 'db_path  ' . ($cfg->{db_path} // '')),
		_fit($width, 'dish  ' . ($meta->{dish_host} // '') . ':' . ($meta->{dish_port} // '')),
		_fit($width, 'http_port  ' . ($page->{http_port} // '')),
		_fit($width, 'history_samples  ' . ($page->{history_n} // 0)),
		_fit($width, 'listen  ' . ($meta->{listen} // '')),
		_fit($width, 'sample  ' . ($meta->{sample_s} // '') . 's'
		    . '    map  ' . ($meta->{map_s} // '') . 's'),
		_fit($width, 'retention  raw ' . ($meta->{raw_days} // '')
		    . 'd  minutely ' . ($meta->{minute_days} // '')
		    . 'd  hourly ' . ($meta->{hour_days} // '') . 'd'),
	);
	return @out;
}

sub _stats {
	my ($latest, $width) = @_;
	my $lat = _n($latest->{ping_latency_ms});
	my $loss = _n($latest->{ping_drop_rate});
	my $ob = _n($latest->{obstr_fraction});
	return (
		_fit($width, 'down  ' . SLMON::Dash::fmt_rate($latest->{downlink_bps})
		    . '   up  ' . SLMON::Dash::fmt_rate($latest->{uplink_bps})
		    . '   rtt  ' . (defined $lat ? sprintf('%.0f ms', $lat) : 'n/a')),
		_fit($width, 'loss  ' . (defined $loss ? sprintf('%.1f%%', $loss * 100) : 'n/a')
		    . '   obstr  ' . (defined $ob ? sprintf('%.3f%%', $ob * 100) : 'n/a')
		    . '   uptime  ' . SLMON::Dash::fmt_uptime($latest->{uptime_s})),
	);
}

sub _open_lines {
	my ($events, $now, $width) = @_;
	my @open = SLMON::Dash::open_events($events, $now);
	return _fit($width, 'open  none') if !@open;
	my @lines;
	for my $ev (@open) {
		my $line = 'open  ' . $ev->{ts} . ' ' . $ev->{type};
		$line .= ' ' . $ev->{details}
		    if defined $ev->{details} && $ev->{details} ne '';
		push @lines, _fit($width, $line);
	}
	return @lines;
}

# Lines left for every chart on the view, after the header and footer.
sub _chart_budget {
	my ($height, $foot_n, $fixed) = @_;
	return undef if !$height;
	return $height - 1 - ($foot_n || 0) - ($fixed || 0);
}

# Plot rows for each chart. Three is the short-terminal size. Extra
# rows are split across the charts so a taller window draws taller plots.
sub _plot_rows {
	my ($n, $budget) = @_;
	return () if $n < 1;
	return (3) x $n if !defined $budget;
	# Title, baseline, and the time line sit outside the plot.
	my $plot_total = $budget - 3 * $n;
	return (3) x $n if $plot_total < 3 * $n;
	my $base = int($plot_total / $n);
	my $rem = $plot_total % $n;
	return map { $base + ($_ < $rem ? 1 : 0) } 0 .. $n - 1;
}

sub _charts_or_note {
	my ($width, $label, $from, $to, $series, $titles, $budget) = @_;
	if ($width < 80) {
		return _fit($width, 'chart needs a wider terminal');
	}
	my @rows = _plot_rows(scalar @$series, $budget);
	my @out;
	for my $i (0 .. $#$series) {
		push @out, _chart($width, $titles->[$i][0], $titles->[$i][1],
		    $series->[$i], $from, $to, $rows[$i]);
	}
	return @out;
}

sub _chart {
	my ($width, $title, $unit, $pts, $from, $to, $rows) = @_;
	my $lab = 6;
	my $cols = $width - $lab - 2;
	$cols = 10 if $cols < 10;
	my ($bins, $max) = _bins($pts, $from, $to, $cols);
	my $max_s = $unit eq 'down' || $unit eq 'up'
	    ? SLMON::Dash::fmt_rate($max)
	    : (defined $max && $max > 0 ? sprintf('%.1f %s', $max, $unit) : 'n/a');
	my @lines = (_fit($width, "$title, max $max_s"));
	return @lines, _fit($width, 'no samples') if !defined $max || $max <= 0;
	$rows = 3 if !$rows || $rows < 1;
	my $levels = $rows * 8;
	for my $r (0 .. $rows - 1) {
		my $floor = ($rows - 1 - $r) * 8;
		my $plot = '';
		for my $i (0 .. $cols - 1) {
			my $v = $bins->[$i];
			my $h = 0;
			if (defined $v && $v > 0) {
				$h = int($v / $max * $levels + 0.999);
				$h = 1 if $h < 1;
				$h = $levels if $h > $levels;
			}
			my $have = $h - $floor;
			if ($have >= 8) {
				$plot .= '#';
			} elsif ($have > 0) {
				$plot .= $MARK[$have];
			} else {
				$plot .= ' ';
			}
		}
		my $gutter = $r == 0 ? _axis($max, $unit) : ($r == $rows - 1 ? '0' : '');
		$gutter = sprintf("%-${lab}s", substr($gutter, 0, $lab));
		push @lines, _fit($width, "$gutter |$plot");
	}
	push @lines, _fit($width, (' ' x ($lab + 1)) . '+' . ('-' x $cols));
	my $times = _time_axis($from, $to, $cols);
	push @lines, (' ' x ($lab + 2)) . $times if $times ne '';
	return @lines;
}

# Even times across the plot. The finest step that divides the span
# and still leaves a gap between labels wins. A narrower plot drops
# to a coarser step.
sub _time_axis {
	my ($from, $to, $cols) = @_;
	return '' if !defined $from || !defined $to || $to <= $from || $cols < 4;
	my $span = $to - $from;
	my @step = (
		1, 2, 5, 10, 15, 30,
		60, 120, 300, 600, 900, 1200, 1800,
		3600, 7200, 10800, 14400, 21600, 43200,
		86400, 2 * 86400, 3 * 86400, 5 * 86400, 7 * 86400,
		14 * 86400, 30 * 86400,
	);
	my $gap = 2;
	for my $step (@step) {
		next if $span < $step || $span % $step != 0;
		my $n = int($span / $step) + 1;
		next if $n < 2 || $n > int($cols / 3);
		my $unit = _axis_unit($step, $span);
		my @text;
		my %seen;
		my $dup = 0;
		for my $i (0 .. $n - 1) {
			my $ago = $span - $step * $i;
			my $label = _ago_label($ago, $unit);
			$dup = 1 if $seen{$label}++;
			push @text, $label;
		}
		next if $dup;
		my $placed = _place_labels(\@text, $cols, $gap);
		return $placed if defined $placed && $placed ne '';
	}
	my @ends = (_ago_label($span, 'auto'), 'now');
	my $placed = _place_labels(\@ends, $cols, $gap);
	return $placed if defined $placed;
	return '';
}

# One unit for every tick. A multi-day window whose step is a whole
# number of hours says "6d12h", so the line does not mix 156h with 7d.
sub _axis_unit {
	my ($step, $span) = @_;
	return 'd' if $step % 86400 == 0;
	return 'dh' if $step % 3600 == 0 && $span >= 2 * 86400;
	return 'h' if $step % 3600 == 0;
	return 'm' if $step % 60 == 0;
	return 's';
}

sub _ago_label {
	my ($ago, $unit) = @_;
	return 'now' if !defined $ago || $ago < 0.5;
	$ago = int($ago + 0.5);
	$unit ||= 'auto';
	if ($unit eq 'd') {
		return '-' . int($ago / 86400) . 'd';
	}
	if ($unit eq 'dh') {
		my $h = int($ago / 3600);
		my $d = int($h / 24);
		$h %= 24;
		return '-' . $d . 'd' if $h == 0;
		return '-' . $h . 'h' if $d == 0;
		return '-' . $d . 'd' . $h . 'h';
	}
	if ($unit eq 'h') {
		return '-' . int($ago / 3600) . 'h';
	}
	if ($unit eq 'm') {
		return '-' . int($ago / 60) . 'm';
	}
	if ($unit eq 's') {
		return '-' . $ago . 's';
	}
	return '-' . int($ago / 86400) . 'd' if $ago % 86400 == 0;
	return '-' . int($ago / 3600) . 'h' if $ago % 3600 == 0;
	return '-' . int($ago / 60) . 'm' if $ago % 60 == 0;
	return '-' . $ago . 's';
}

# Start column of each label, centered on an even tick. Endpoints stay
# inside the plot. A label may slide two columns so a clamped end does
# not throw away a finer step. Neighbors keep $gap spaces. Undef when
# they cannot.
sub _place_labels {
	my ($labels, $cols, $gap) = @_;
	my $n = @$labels;
	return '' if $n < 1;
	my (@len, @ideal);
	for my $i (0 .. $n - 1) {
		my $len = length $labels->[$i];
		return undef if $len < 1 || $len > $cols;
		$len[$i] = $len;
		my $at = $n == 1 ? 0 : $i / ($n - 1) * ($cols - 1);
		my $origin = int($at - ($len - 1) / 2 + 0.5);
		$origin = 0 if $origin < 0;
		$origin = $cols - $len if $origin + $len > $cols;
		$ideal[$i] = $origin;
	}
	my @start = @ideal;
	for my $i (1 .. $n - 1) {
		my $min = $start[$i - 1] + $len[$i - 1] + $gap;
		$start[$i] = $min if $start[$i] < $min;
	}
	if ($start[$n - 1] + $len[$n - 1] > $cols) {
		$start[$n - 1] = $cols - $len[$n - 1];
		for (my $i = $n - 2; $i >= 0; $i--) {
			my $max = $start[$i + 1] - $gap - $len[$i];
			$start[$i] = $max if $start[$i] > $max;
		}
	}
	for my $i (0 .. $n - 1) {
		return undef if $start[$i] < 0 || $start[$i] + $len[$i] > $cols;
		return undef if abs($start[$i] - $ideal[$i]) > 2;
	}
	for my $i (1 .. $n - 1) {
		return undef if $start[$i] < $start[$i - 1] + $len[$i - 1] + $gap;
	}
	my $line = ' ' x $cols;
	for my $i (0 .. $n - 1) {
		substr($line, $start[$i], $len[$i]) = $labels->[$i];
	}
	return $line;
}

sub _bins {
	my ($pts, $from, $to, $cols) = @_;
	my @bin;
	my $max = 0;
	return (\@bin, $max) if !defined $from || !defined $to || $to <= $from;
	my $span = $to - $from;
	for my $p (@{ $pts || [] }) {
		my $t = $p->{t};
		my $v = $p->{v};
		next if !defined $t || !defined $v || $t < $from || $t > $to;
		my $i = int(($t - $from) / $span * $cols);
		$i = $cols - 1 if $i >= $cols;
		$i = 0 if $i < 0;
		$bin[$i] = $v if !defined $bin[$i] || $v > $bin[$i];
		$max = $v if $v > $max;
	}
	return (\@bin, $max);
}

sub _axis {
	my ($max, $unit) = @_;
	return '0' if !defined $max || $max <= 0;
	if ($unit eq 'down' || $unit eq 'up') {
		return sprintf('%.0fM', $max / 1_000_000) if $max >= 100_000_000;
		return sprintf('%.1fM', $max / 1_000_000) if $max >= 1_000_000;
		return sprintf('%.0fk', $max / 1000) if $max >= 1000;
		return sprintf('%.0f', $max);
	}
	return sprintf('%.0f', $max);
}

sub _hour_pts {
	my ($rows, $key) = @_;
	my @out;
	for my $row (@{ $rows || [] }) {
		my $t = _n($row->{ts});
		next if !defined $t;
		push @out, { t => $t, v => _n($row->{$key}) };
	}
	return \@out;
}

sub _keyed {
	my ($pts, $key) = @_;
	my @out;
	for my $p (@{ $pts || [] }) {
		push @out, { t => $p->{t}, v => $p->{$key} };
	}
	return \@out;
}

sub _scaled {
	my ($pts, $key, $mul) = @_;
	my @out;
	for my $p (@{ $pts || [] }) {
		my $v = $p->{$key};
		$v = $v * $mul if defined $v;
		push @out, { t => $p->{t}, v => $v };
	}
	return \@out;
}

sub _weather_word {
	my ($rows) = @_;
	return 'n/a' if ref $rows ne 'ARRAY' || !@$rows;
	my $newest;
	for my $row (@$rows) {
		my $ts = _n($row->{ts});
		$ts = -1 if !defined $ts;
		$newest = $row if !defined $newest || $ts >= (_n($newest->{ts}) // -1);
	}
	my $w = $newest->{warning};
	return (defined $w && $w ne '') ? $w : 'normal';
}

sub _map_lines {
	my ($row, $az, $el, $width, $max_rows) = @_;
	return _fit($width, 'no obstruction map stored') if ref $row ne 'HASH';
	my $rows = int($row->{num_rows} // 0);
	my $cols = int($row->{num_cols} // 0);
	return _fit($width, 'no obstruction map stored') if $rows < 1 || $cols < 1;
	my $raw = eval { decode_base64($row->{snr_b64} // '') };
	return _fit($width, 'no obstruction map stored') if !defined $raw;
	my @v = unpack('f<*', $raw);
	return _fit($width, 'no obstruction map stored') if @v < $rows * $cols;
	# A terminal cell is about twice as tall as it is wide, so a round
	# sky uses two columns per row. Both axes follow the terminal.
	my $dc = $width < 1 ? 1 : $width;
	my $dr = int($dc * $rows / $cols / 2);
	$dr = 1 if $dr < 1;
	if ($max_rows && $max_rows > 0 && $dr > $max_rows) {
		$dr = $max_rows;
		$dc = int($dr * 2 * $cols / $rows);
		$dc = 1 if $dc < 1;
		$dc = $width if $dc > $width;
	}
	my @grid;
	for my $r (0 .. $dr - 1) {
		my $line = '';
		for my $c (0 .. $dc - 1) {
			my $kind = ' ';
			my $r0 = int($r * $rows / $dr);
			my $r1 = int(($r + 1) * $rows / $dr);
			my $c0 = int($c * $cols / $dc);
			my $c1 = int(($c + 1) * $cols / $dc);
			$r1 = $r0 + 1 if $r1 <= $r0;
			$c1 = $c0 + 1 if $c1 <= $c0;
			for my $rr ($r0 .. $r1 - 1) {
				last if $rr >= $rows;
				for my $cc ($c0 .. $c1 - 1) {
					last if $cc >= $cols;
					my $val = $v[$rr * $cols + $cc];
					next if !defined $val || $val < 0;
					if ($val == 0) {
						$kind = '#';
					} elsif ($kind ne '#') {
						$kind = '.';
					}
				}
			}
			$line .= $kind;
		}
		push @grid, $line;
	}
	my ($bx, $by) = SLMON::Dash::_bore_src($cols, $rows, $az, $el);
	if (defined $bx) {
		my $c = int($bx / $cols * $dc);
		my $r = int($by / $rows * $dr);
		$c = $dc - 1 if $c >= $dc;
		$r = $dr - 1 if $r >= $dr;
		$c = 0 if $c < 0;
		$r = 0 if $r < 0;
		substr($grid[$r], $c, 1) = '+';
	}
	my @out = (_fit($width, 'map  space unmeasured  . clear  # blocked  + boresight'));
	# Keep a row of spaces. _fit would drop it, and the sky would collapse.
	push @out, @grid;
	return @out;
}

sub _calendar {
	my ($page, $width, $now) = @_;
	my $from = $page->{window_from};
	my $to = $page->{window_to} // $now;
	$from = $to - 86400 if !defined $from;
	return 'calendar  none' if $to <= $from;
	my @spans = SLMON::Dash::_merge_spans(
	    SLMON::Dash::_outage_spans($page->{sla_events} || $page->{events}, $to));
	my $cols = $width - 12;
	$cols = 8 if $cols < 8;
	my $span = $to - $from;
	my $marks = '';
	for my $i (0 .. $cols - 1) {
		my $a = $from + $span * $i / $cols;
		my $b = $from + $span * ($i + 1) / $cols;
		my $hit = 0;
		for my $s (@spans) {
			if ($s->{end} > $a && $s->{start} < $b) {
				$hit = 1;
				last;
			}
		}
		$marks .= $hit ? '#' : '.';
	}
	return "calendar  $marks";
}

sub _fit {
	my ($width, $line) = @_;
	$line //= '';
	$line =~ s/\s+\z//;
	return $line if length($line) <= $width;
	return substr($line, 0, $width);
}

# Keys stay readable when the terminal is narrower than the footer.
sub _wrap {
	my ($width, $line) = @_;
	$line //= '';
	$line =~ s/\s+\z//;
	return $line if length($line) <= $width;
	my @out;
	while (length($line) > $width) {
		my $cut = rindex(substr($line, 0, $width + 1), ' ');
		$cut = $width if $cut < 1;
		push @out, substr($line, 0, $cut);
		substr($line, 0, $cut) = '';
		$line =~ s/\A\s+//;
	}
	push @out, $line if $line ne '';
	return @out;
}

sub _n {
	my ($v) = @_;
	return undef if !defined $v || $v eq '';
	return undef if $v !~ /\A-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/;
	return $v + 0;
}

sub winsize {
	my $pack = pack('S4', 0, 0, 0, 0);
	# OpenBSD TIOCGWINSZ.
	if (ioctl(STDOUT, 0x40087468, $pack)) {
		my ($row, $col) = unpack('S2', $pack);
		return ($col, $row) if $col && $row;
	}
	my $col = $ENV{COLUMNS};
	my $row = $ENV{LINES};
	$col = 80 if !defined $col || $col !~ /\A[0-9]+\z/ || $col < 1;
	$row = 24 if !defined $row || $row !~ /\A[0-9]+\z/ || $row < 1;
	return ($col, $row);
}

sub loop {
	my ($cfg, $interval) = @_;
	$interval = 3 if !defined $interval || $interval < 1;
	my $termios = POSIX::Termios->new();
	$termios->getattr(fileno(STDIN));
	my $saved = POSIX::Termios->new();
	$saved->getattr(fileno(STDIN));
	my $lflag = $termios->getlflag();
	$termios->setlflag($lflag & ~(POSIX::ECHO | POSIX::ICANON));
	$termios->setcc(POSIX::VMIN, 0);
	$termios->setcc(POSIX::VTIME, 0);
	$termios->setattr(fileno(STDIN), POSIX::TCSANOW);
	my $restore = sub {
		$saved->setattr(fileno(STDIN), POSIX::TCSANOW);
		print "\e[?25h\e[?1049l";
		STDOUT->flush if STDOUT->can('flush');
	};
	local $SIG{INT} = sub { $restore->(); exit 0 };
	local $SIG{TERM} = sub { $restore->(); exit 0 };
	my $winch = 0;
	local $SIG{WINCH} = sub { $winch = 1 };
	local $| = 1;
	print "\e[?1049h\e[?25l";
	my $state = { view => 'overview', range => '24h', interval => $interval };
	my $quit = 0;
	while (!$quit) {
		$winch = 0;
		my $dbh = eval { SLMON::DB::open_db($cfg, readonly => 1) };
		if (!$dbh) {
			$restore->();
			print "database: closed\n";
			return 1;
		}
		my $page = eval { load($dbh, $cfg, $state->{range}, time) };
		my ($cols, $rows) = winsize();
		my $text = $page
		    ? frame($page,
			view => $state->{view}, range => $state->{range},
			interval => $state->{interval}, width => $cols,
			height => $rows, now => $page->{now})
		    : "database: $@" ;
		print "\e[2J\e[H", $text;
		my $deadline = time + $state->{interval};
		while (time < $deadline && !$quit && !$winch) {
			my $rin = '';
			vec($rin, fileno(STDIN), 1) = 1;
			my $left = $deadline - time;
			$left = 0.1 if $left < 0.1;
			my $n = select($rin, undef, undef, $left);
			last if $winch;
			next if !$n;
			my $buf = '';
			sysread STDIN, $buf, 32;
			for my $ch (split //, $buf) {
				next if $ch eq "\e" || ord($ch) < 32;
				$quit = 1 if !apply_key($state, $ch);
				$deadline = time if !$quit;
			}
		}
	}
	$restore->();
	return 0;
}

1;
