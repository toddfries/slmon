package SLMON::Dash;

use strict;
use warnings;

use MIME::Base64 qw(decode_base64);
use POSIX qw(strftime);
use SLMON ();
use SLMON::Config;
use SLMON::StatusMap;

my %RANGE = (
	'24h'  => 86400,
	'7d'   => 7 * 86400,
	'30d'  => 30 * 86400,
	'365d' => 365 * 86400,
	'ever' => undef,
);

sub range_seconds {
	my ($name) = @_;
	$name = range_name($name);
	return $RANGE{$name};
}

sub range_name {
	my ($name) = @_;
	return $name if defined $name && exists $RANGE{$name};
	return '24h';
}

# True when a rollup tier already carries an obstruction fraction.
# A stored zero counts. Null does not.
sub tier_has_obstr {
	my ($rows) = @_;
	for my $row (@{ $rows || [] }) {
		return 1 if defined _num($row->{avg_obstr_fraction} // $row->{obstr_fraction});
	}
	return 0;
}

sub series_table {
	my ($name) = @_;
	$name = range_name($name);
	return 'metrics_minutely' if $name eq '24h';
	return 'metrics_hourly' if $name eq '7d' || $name eq '30d';
	return 'metrics_daily';
}

# Daily rollup stops at the UTC day boundary, and only for days it has
# already written. Hours for a missing day still have to be drawn.
sub hourly_tail {
	my ($name) = @_;
	$name = range_name($name);
	return $name eq '365d' || $name eq 'ever' ? 1 : 0;
}

sub merge_unrolled {
	my ($daily, $hourly) = @_;
	my %day;
	for my $row (@{ $daily || [] }) {
		my $ts = _num($row->{ts_day});
		$day{$ts} = 1 if defined $ts;
	}
	my @out = @{ $daily || [] };
	for my $row (@{ $hourly || [] }) {
		my $ts = _num($row->{ts_hour});
		next if !defined $ts;
		my $d = $ts - ($ts % 86400);
		next if $day{$d};
		push @out, $row;
	}
	return \@out;
}

sub _num {
	my ($v) = @_;
	return undef if !defined $v || $v eq '';
	return undef if $v !~ /\A-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/;
	return $v + 0;
}

sub _he {
	my ($s) = @_;
	$s //= '';
	$s =~ s/&/&amp;/g;
	$s =~ s/</&lt;/g;
	$s =~ s/>/&gt;/g;
	$s =~ s/"/&quot;/g;
	return $s;
}

sub _ts {
	my ($row) = @_;
	return _num($row->{ts} // $row->{ts_minute} // $row->{ts_hour} // $row->{ts_day});
}

sub points {
	my ($rows) = @_;
	my @out;
	for my $row (@{ $rows || [] }) {
		my $ts = _ts($row);
		next if !defined $ts;
		push @out, {
			t       => $ts,
			down    => _num($row->{downlink_bps} // $row->{avg_downlink_bps}),
			up      => _num($row->{uplink_bps} // $row->{avg_uplink_bps}),
			lat     => _num($row->{ping_latency_ms} // $row->{avg_ping_latency_ms}),
			lat_max => _num($row->{max_ping_latency_ms}),
			drop    => _num($row->{ping_drop_rate} // $row->{avg_ping_drop_rate}),
			obstr   => _num($row->{obstr_fraction} // $row->{avg_obstr_fraction}),
			jitter  => _num($row->{jitter_ms}),
		};
	}
	@out = sort { $a->{t} <=> $b->{t} } @out;
	return \@out;
}

sub _earliest {
	my (@lists) = @_;
	my $t;
	for my $pts (@lists) {
		for my $p (@{ $pts || [] }) {
			next if !defined $p->{t};
			$t = $p->{t} if !defined $t || $p->{t} < $t;
		}
	}
	return $t;
}

sub fmt_rate {
	my ($bps) = @_;
	return 'n/a' if !defined _num($bps);
	$bps = _num($bps);
	my $abs = abs($bps);
	return sprintf('%.1f Mbit/s', $bps / 1_000_000) if $abs >= 1_000_000;
	return sprintf('%.0f kbit/s', $bps / 1000) if $abs >= 1000;
	return sprintf('%.0f bit/s', $bps);
}

sub fmt_uptime {
	my ($s) = @_;
	return 'n/a' if !defined _num($s);
	$s = int(_num($s));
	$s = 0 if $s < 0;
	my $d = int($s / 86400);
	$s %= 86400;
	my $h = int($s / 3600);
	$s %= 3600;
	my $m = int($s / 60);
	return "${d}d ${h}h" if $d;
	return "${h}h ${m}m" if $h;
	return "${m}m";
}

sub _fmt_clock {
	my ($ts, $span) = @_;
	return '' if !defined $ts;
	my $fmt = '%H:%M';
	if (!defined $span || $span > 30 * 86400) {
		$fmt = '%Y-%m-%d';
	} elsif ($span > 86400) {
		$fmt = '%m-%d';
	}
	return strftime($fmt, localtime($ts));
}

sub _nice_max {
	my ($v) = @_;
	return 1 if !defined $v || $v <= 0;
	my $exp = int(log($v) / log(10));
	$exp-- if $v < 1 && (10 ** $exp) > $v;
	my $p = 10 ** $exp;
	my $n = $v / $p;
	my $m = $n <= 1 ? 1 : $n <= 2 ? 2 : $n <= 5 ? 5 : 10;
	return $m * $p;
}

sub _bucket {
	my ($pts, $max) = @_;
	return $pts if @$pts <= $max;
	my @out;
	my $n = @$pts;
	my $step = $n / $max;
	for (my $i = 0; $i < $max; $i++) {
		my $a = int($i * $step);
		my $b = int(($i + 1) * $step) - 1;
		$b = $a if $b < $a;
		$b = $n - 1 if $b >= $n;
		my ($sum, $c, $peak);
		for my $k ($a .. $b) {
			next if !defined $pts->[$k]{v};
			$sum += $pts->[$k]{v};
			$c++;
			my $mx = $pts->[$k]{vmax};
			$peak = $mx if defined $mx && (!defined $peak || $mx > $peak);
		}
		next if !$c;
		push @out, { t => $pts->[$a]{t}, v => $sum / $c, vmax => $peak };
	}
	return \@out;
}

sub _axis {
	my ($v) = @_;
	return '0' if !defined $v || abs($v) < 1e-12;
	return sprintf('%.2f', $v) if abs($v) < 10;
	return sprintf('%.0f', $v);
}

# points are {t, v, vmax}. v is already in display units.
sub chart_svg {
	my (%o) = @_;
	my $title = $o{title} // '';
	my $unit = $o{unit} // '';
	my $from = $o{from};
	my $to = $o{to};
	my $pts = $o{points} || [];
	$from = $pts->[0]{t} if !defined $from && @$pts;
	$to = $pts->[-1]{t} if !defined $to && @$pts;
	$from //= 0;
	$to //= $from + 1;
	$to = $from + 1 if $to <= $from;
	my $W = 720;
	my $H = 200;
	my ($left, $right, $top, $bot) = (58, 12, 16, 28);
	my $pw = $W - $left - $right;
	my $ph = $H - $top - $bot;
	my @drawn = grep { defined $_->{v} } @$pts;
	my $span = $to - $from;
	my $label_span = exists $o{label_span} ? $o{label_span} : $span;
	my $body;
	if (!@drawn) {
		$body = '<text class="empty" x="' . int($W / 2) . '" y="' . int($H / 2)
		    . '" text-anchor="middle">No samples in this window</text>';
	} else {
		my $ymax = 0;
		for my $p (@drawn) {
			$ymax = $p->{v} if $p->{v} > $ymax;
			$ymax = $p->{vmax} if defined $p->{vmax} && $p->{vmax} > $ymax;
		}
		$ymax = _nice_max($ymax);
		my $x_of = sub {
			my ($t) = @_;
			return $left + ($t - $from) / $span * $pw;
		};
		my $y_of = sub {
			my ($v) = @_;
			return $top + $ph - ($v / $ymax) * $ph;
		};
		my @grid;
		for my $i (0, 1, 2) {
			my $val = $ymax * $i / 2;
			my $y = sprintf('%.1f', $y_of->($val));
			push @grid, qq{<line x1="$left" y1="$y" x2="} . ($W - $right) . qq{" y2="$y"/>};
			push @grid, '<text x="' . ($left - 8) . qq{" y="$y" text-anchor="end">}
			    . _axis($val) . '</text>';
		}
		my @xy;
		my @peak;
		for my $p (@drawn) {
			push @xy, sprintf('%.1f,%.1f', $x_of->($p->{t}), $y_of->($p->{v}));
			push @peak, sprintf('%.1f,%.1f', $x_of->($p->{t}), $y_of->($p->{vmax}))
			    if defined $p->{vmax};
		}
		$body = join('', @grid);
		if (@peak > 1) {
			$body .= '<polyline class="peak" points="' . join(' ', @peak) . '"/>';
		}
		if (@xy == 1) {
			$body .= '<circle class="series" cx="' . (split /,/, $xy[0])[0]
			    . '" cy="' . (split /,/, $xy[0])[1] . '" r="2.5"/>';
		} else {
			$body .= '<polyline class="series" points="' . join(' ', @xy) . '"/>';
		}
		$body .= '<text class="tick" x="' . $left . '" y="' . ($H - 8) . '">'
		    . _he(_fmt_clock($from, $label_span)) . '</text>';
		$body .= '<text class="tick" x="' . ($W - $right) . '" y="' . ($H - 8)
		    . '" text-anchor="end">' . _he(_fmt_clock($to, $label_span)) . '</text>';
	}
	my $cap = _he($title);
	$cap .= ' (' . _he($unit) . ')' if $unit ne '';
	return '<svg viewBox="0 0 ' . $W . ' ' . $H . '" role="img">'
	    . '<title>' . $cap . '</title>'
	    . $body
	    . '</svg>';
}

sub _series_chart {
	my ($title, $unit, $key, $pts, $from, $to, $mul, $label_span) = @_;
	$mul //= 1;
	my @p;
	for my $row (@$pts) {
		my $v = $row->{$key};
		next if !defined $v;
		my $mx = $key eq 'lat' ? $row->{lat_max} : undef;
		push @p, {
			t    => $row->{t},
			v    => $v * $mul,
			vmax => defined $mx ? $mx * $mul : undef,
		};
	}
	@p = @{ _bucket(\@p, 480) };
	return chart_svg(
		title      => $title,
		unit       => $unit,
		from       => $from,
		to         => $to,
		label_span => $label_span,
		points     => \@p,
	);
}

sub _rate_unit {
	my ($pts, $key) = @_;
	my $max = 0;
	for my $p (@$pts) {
		my $v = $p->{$key};
		$max = $v if defined $v && $v > $max;
	}
	return (1_000_000, 'Mbit/s') if $max >= 1_000_000;
	return (1000, 'kbit/s') if $max >= 1000;
	return (1, 'bit/s');
}

sub map_svg {
	my ($row) = @_;
	return '' if !$row;
	my $rows = int($row->{num_rows} // 0);
	my $cols = int($row->{num_cols} // 0);
	return '' if $rows < 1 || $cols < 1;
	my $raw = eval { decode_base64($row->{snr_b64} // '') };
	return '' if !defined $raw;
	my @v = unpack('f<*', $raw);
	return '' if @v < $rows * $cols;
	my $long = $rows > $cols ? $rows : $cols;
	my $step = int(($long + 47) / 48);
	$step = 1 if $step < 1;
	my $orows = int(($rows + $step - 1) / $step);
	my $ocols = int(($cols + $step - 1) / $step);
	my $cell = 8;
	my $svg = '<svg class="obstruction" viewBox="0 0 ' . ($ocols * $cell)
	    . ' ' . ($orows * $cell) . '" role="img"><title>Obstruction map</title>';
	for (my $r = 0; $r < $orows; $r++) {
		for (my $c = 0; $c < $ocols; $c++) {
			my $kind = 'u';
			for (my $rr = $r * $step; $rr < $rows && $rr < ($r + 1) * $step; $rr++) {
				for (my $cc = $c * $step; $cc < $cols && $cc < ($c + 1) * $step; $cc++) {
					my $val = $v[$rr * $cols + $cc];
					next if !defined $val || $val < 0;
					if ($val == 0) {
						$kind = 'o';
					} elsif ($kind ne 'o') {
						$kind = 'c';
					}
				}
			}
			$svg .= '<rect class="' . $kind . '" x="' . ($c * $cell) . '" y="'
			    . ($r * $cell) . '" width="' . $cell . '" height="' . $cell . '"/>';
		}
	}
	$svg .= '</svg>';
	return $svg;
}

sub _figure {
	my ($svg) = @_;
	my ($title) = $svg =~ m{<title>([^<]*)</title>};
	my $note = $svg =~ /class="peak"/
	    ? '<p class="note">Dashed line is the maximum.</p>' : '';
	return '<figure><h2>' . ($title // '') . '</h2>' . $note . $svg . '</figure>';
}

sub _stat {
	my ($label, $value) = @_;
	return '<div class="stat"><span>' . _he($label) . '</span><b>'
	    . _he($value) . '</b></div>';
}

sub _day {
	my ($v, $default) = @_;
	return $default if !defined $v || $v !~ /\A[0-9]+\z/;
	return int($v);
}

sub _span {
	my ($s) = @_;
	$s = int($s // 0);
	return int($s / 60) . ' min' if $s >= 60 && $s % 60 == 0;
	return $s . 's';
}

# What the page is allowed to show. Secrets stay out.
sub view_from {
	my ($cfg) = @_;
	$cfg = {} if ref $cfg ne 'HASH';
	my $sample = $cfg->{dish_interval_s};
	$sample = 30 if !defined $sample || $sample !~ /\A[0-9]+\z/;
	$sample = int($sample);
	$sample = SLMON::MIN_POLL_S if $sample < SLMON::MIN_POLL_S;
	my $host = $cfg->{dish_host};
	$host = '192.168.100.1' if !defined $host || $host eq '';
	my ($dish_host, $dish_port) = SLMON::Config::dish_endpoint({ dish_host => $host });
	my $db = $cfg->{db};
	$db = 'sqlite' if !defined $db || ($db ne 'sqlite' && $db ne 'pg');
	my $listen = $cfg->{listen};
	$listen = '127.0.0.1:8080' if !defined $listen || $listen eq '';
	return {
		dish_host   => $dish_host,
		dish_port   => $dish_port,
		sample_s    => $sample,
		chart_s     => $sample,
		map_s       => SLMON::MAP_POLL_S,
		db          => $db,
		listen      => $listen,
		raw_days    => _day($cfg->{raw_retention_days}, 90),
		minute_days => _day($cfg->{minutely_retention_days}, 730),
		hour_days   => _day($cfg->{hourly_rollup_days}, 365),
	};
}

# Stored deflate, so the icon needs no zlib module and can be built
# after the http process has pledged inet.
my @CRC32;
my %ICON_PNG;

sub _crc32 {
	my ($data) = @_;
	if (!@CRC32) {
		for my $n (0 .. 255) {
			my $c = $n;
			for (0 .. 7) {
				$c = ($c & 1) ? (0xedb88320 ^ ($c >> 1)) : ($c >> 1);
			}
			$CRC32[$n] = $c;
		}
	}
	my $crc = 0xffffffff;
	for my $byte (unpack('C*', $data)) {
		$crc = $CRC32[($crc ^ $byte) & 0xff] ^ ($crc >> 8);
	}
	return $crc ^ 0xffffffff;
}

sub _adler32 {
	my ($data) = @_;
	my ($a, $b) = (1, 0);
	for my $c (unpack('C*', $data)) {
		$a = ($a + $c) % 65521;
		$b = ($b + $a) % 65521;
	}
	return ($b << 16) | $a;
}

sub _zlib_store {
	my ($data) = @_;
	my $out = pack('C2', 0x78, 0x01);
	my $off = 0;
	my $len = length($data);
	while ($off < $len) {
		my $n = $len - $off;
		$n = 65535 if $n > 65535;
		my $last = ($off + $n >= $len) ? 1 : 0;
		$out .= pack('C v v', $last, $n, ($n ^ 0xffff) & 0xffff);
		$out .= substr($data, $off, $n);
		$off += $n;
	}
	$out .= pack('N', _adler32($data));
	return $out;
}

sub _png_chunk {
	my ($type, $data) = @_;
	return pack('N', length($data)) . $type . $data
	    . pack('N', _crc32($type . $data));
}

sub _plot {
	my ($buf, $size, $x, $y, $thick, $fg) = @_;
	my $r = int($thick / 2);
	for my $dy (-$r .. $r) {
		for my $dx (-$r .. $r) {
			next if ($dx * $dx + $dy * $dy) > ($r * $r);
			my $px = $x + $dx;
			my $py = $y + $dy;
			next if $px < 0 || $py < 0 || $px >= $size || $py >= $size;
			substr($$buf, ($py * $size + $px) * 3, 3) = $fg;
		}
	}
	return;
}

sub _stroke {
	my ($buf, $size, $a, $b, $thick, $fg) = @_;
	my $x0 = int($a->[0] * ($size - 1));
	my $y0 = int($a->[1] * ($size - 1));
	my $x1 = int($b->[0] * ($size - 1));
	my $y1 = int($b->[1] * ($size - 1));
	my $dx = abs($x1 - $x0);
	my $dy = abs($y1 - $y0);
	my $sx = $x0 < $x1 ? 1 : -1;
	my $sy = $y0 < $y1 ? 1 : -1;
	my $err = $dx - $dy;
	while (1) {
		_plot($buf, $size, $x0, $y0, $thick, $fg);
		last if $x0 == $x1 && $y0 == $y1;
		my $e2 = 2 * $err;
		if ($e2 > -$dy) { $err -= $dy; $x0 += $sx; }
		if ($e2 < $dx) { $err += $dx; $y0 += $sy; }
	}
	return;
}

sub _icon_rgb {
	my ($size) = @_;
	my $buf = pack('C3', 0x1d, 0x4e, 0x89) x ($size * $size);
	my $fg = pack('C3', 255, 255, 255);
	my $thick = int($size / 28);
	$thick = 3 if $thick < 3;
	my @pts = ([0.28, 0.68], [0.42, 0.44], [0.58, 0.56], [0.72, 0.32]);
	for my $i (0 .. $#pts - 1) {
		_stroke(\$buf, $size, $pts[$i], $pts[$i + 1], $thick, $fg);
	}
	return $buf;
}

sub icon_png {
	my ($size) = @_;
	return $ICON_PNG{$size} if defined $ICON_PNG{$size};
	my $rgb = _icon_rgb($size);
	my $stride = $size * 3;
	my $raw = '';
	for (my $y = 0; $y < $size; $y++) {
		$raw .= "\x00" . substr($rgb, $y * $stride, $stride);
	}
	my $ihdr = pack('NNC5', $size, $size, 8, 2, 0, 0, 0);
	$ICON_PNG{$size} = "\x89PNG\r\n\x1a\n"
	    . _png_chunk('IHDR', $ihdr)
	    . _png_chunk('IDAT', _zlib_store($raw))
	    . _png_chunk('IEND', '');
	return $ICON_PNG{$size};
}

sub manifest_body {
	return '{"name":"slmon","short_name":"slmon","start_url":"/","scope":"/",'
	    . '"display":"standalone","background_color":"#ffffff","theme_color":"#1d4e89",'
	    . '"icons":['
	    . '{"src":"/icon-192.png","sizes":"192x192","type":"image/png","purpose":"any"},'
	    . '{"src":"/icon-512.png","sizes":"512x512","type":"image/png","purpose":"any"}]}';
}

sub sw_body {
	return <<'JS';
self.addEventListener('install', function () {
  self.skipWaiting();
});
self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});
self.addEventListener('fetch', function (event) {
  event.respondWith(fetch(event.request));
});
JS
}

sub live_tags {
	my ($rev, $refresh_s) = @_;
	$rev //= '';
	$refresh_s = 30 if !defined $refresh_s || $refresh_s !~ /\A[0-9]+\z/;
	$refresh_s = int($refresh_s);
	$refresh_s = SLMON::MIN_POLL_S if $refresh_s < SLMON::MIN_POLL_S;
	return '<link rel="manifest" href="/manifest.webmanifest">'
	    . '<link rel="icon" href="/icon-192.png" type="image/png">'
	    . '<meta name="theme-color" content="#1d4e89">'
	    . '<meta name="slmon-rev" content="' . _he($rev) . '">'
	    . '<meta name="slmon-refresh" content="' . $refresh_s . '">';
}

# Reads the meta tags. Values are not interpolated into this text.
# The body has no "</script" sequence.
sub live_script {
	my $js = <<'JS';
(function () {
  var revNode = document.querySelector('meta[name="slmon-rev"]');
  var everyNode = document.querySelector('meta[name="slmon-refresh"]');
  var rev = revNode ? (revNode.getAttribute('content') || '') : '';
  var raw = everyNode ? (everyNode.getAttribute('content') || '') : '';
  var every = parseInt(raw, 10);
  if (!raw || isNaN(every)) every = 30;
  if (every < 2) every = 2;
  function check() {
    fetch('/health', {cache: 'no-store', credentials: 'same-origin'})
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (j && j.rev && rev && j.rev !== rev) location.reload();
      })
      .catch(function () {});
  }
  setInterval(check, 2000);
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(function () {});
  }
  var installBtn = document.getElementById('install');
  var deferred = null;
  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    deferred = e;
    if (installBtn) installBtn.hidden = false;
  });
  if (installBtn) {
    installBtn.addEventListener('click', function () {
      if (!deferred) return;
      var pending = deferred;
      deferred = null;
      pending.prompt();
      pending.userChoice.then(function () {
        installBtn.hidden = true;
      });
    });
  }
  window.addEventListener('appinstalled', function () {
    deferred = null;
    if (installBtn) installBtn.hidden = true;
  });
  if (!document.getElementById('live')) return;
  function advance() {
    fetch(location.pathname + location.search, {cache: 'no-store', credentials: 'same-origin'})
      .then(function (r) {
        if (r.redirected || r.status === 401) {
          location.assign('/login');
          return null;
        }
        if (!r.ok) return null;
        return r.text();
      })
      .then(function (html) {
        if (!html) return;
        var doc = new DOMParser().parseFromString(html, 'text/html');
        var nextRevNode = doc.querySelector('meta[name="slmon-rev"]');
        var nextRev = nextRevNode ? (nextRevNode.getAttribute('content') || '') : '';
        if (nextRev && rev && nextRev !== rev) {
          location.reload();
          return;
        }
        var next = doc.getElementById('live');
        var cur = document.getElementById('live');
        if (!next || !cur) {
          if (doc.querySelector('form[action="/login"]')) location.assign('/login');
          return;
        }
        cur.innerHTML = next.innerHTML;
        var drawn = next.getAttribute('data-drawn');
        if (drawn) cur.setAttribute('data-drawn', drawn);
      })
      .catch(function () {});
  }
  setInterval(advance, every * 1000);
})();
JS
	return '<script>' . $js . '</script>';
}

sub page {
	my ($d) = @_;
	$d ||= {};
	my $user = $d->{user} // '';
	my $range = range_name($d->{range});
	my $now = $d->{now} // time;
	my $sec = range_seconds($range);
	my $from;
	if (exists $d->{window_from}) {
		$from = $d->{window_from};
	} elsif (defined $sec) {
		$from = $now - $sec;
	}
	my $to = $d->{window_to} // $now;
	my $pts = points($d->{series});
	my $obpts = points(defined $d->{obstruction} ? $d->{obstruction} : $d->{series});
	my $jpts = points(defined $d->{jitter} ? $d->{jitter} : $d->{series});
	my $latest = $d->{latest} || {};
	my $info = $d->{info} || {};
	my ($dscale, $dunit) = _rate_unit($pts, 'down');
	my ($uscale, $uunit) = _rate_unit($pts, 'up');
	# ever has no stored start. The axis begins at the first drawn point.
	my $axis_from = defined $from ? $from : _earliest($pts, $obpts, $jpts);
	my $quality = join '', map { _figure($_) } (
		_series_chart('Packet loss', '%', 'drop', $pts, $axis_from, $to, 100, $sec),
		_series_chart('Latency', 'ms', 'lat', $pts, $axis_from, $to, 1, $sec),
		_series_chart('Jitter', 'ms', 'jitter', $jpts, $axis_from, $to, 1, $sec),
		_series_chart('Obstruction', '%', 'obstr', $obpts, $axis_from, $to, 100, $sec),
	);
	my $throughput = join '', map { _figure($_) } (
		_series_chart('Downlink', $dunit, 'down', $pts, $axis_from, $to, 1 / $dscale, $sec),
		_series_chart('Uplink', $uunit, 'up', $pts, $axis_from, $to, 1 / $uscale, $sec),
	);
	my @nav;
	my %label = (
		'24h'  => '24 hours',
		'7d'   => '7 days',
		'30d'  => '30 days',
		'365d' => '365 days',
		'ever' => 'Ever',
	);
	for my $name (qw(24h 7d 30d 365d ever)) {
		my $cur = $name eq $range ? ' aria-current="page"' : '';
		push @nav, '<a href="/?range=' . $name . '"' . $cur . '>' . $label{$name} . '</a>';
	}
	my $seen = _num($latest->{ts});
	my $stale = defined $seen && ($now - $seen) > 120 ? ' stale' : '';
	my $when = defined $seen ? _fmt_clock($seen, 0) : '';
	my @dish;
	push @dish, $info->{hardware_version} if defined $info->{hardware_version} && $info->{hardware_version} ne '';
	push @dish, $info->{software_version} if defined $info->{software_version} && $info->{software_version} ne '';
	push @dish, 'boot ' . int($info->{bootcount}) if defined _num($info->{bootcount});
	my $az = _num($latest->{direction_azimuth});
	my $el = _num($latest->{direction_elevation});
	push @dish, sprintf('az %.1f° el %.1f°', $az, $el) if defined $az && defined $el;
	my $snr = _num($latest->{snr});
	push @dish, sprintf('SNR %.2f', $snr) if defined $snr;
	my $sats = _num($latest->{gps_sats});
	push @dish, int($sats) . ' GPS sats' if defined $sats;
	my @alerts = SLMON::StatusMap::alert_names($latest->{alerts_bitfield});
	my $alert = @alerts ? '<p class="error">Alerts: ' . _he(join(', ', @alerts)) . '</p>' : '';
	my $err = '';
	if (defined $d->{error} && $d->{error} ne '') {
		$err = '<p class="error">' . _he($d->{error}) . '</p>';
	}
	my $id = '';
	if (defined $info->{device_id} && $info->{device_id} ne '') {
		$id = '<p class="id">' . _he($info->{device_id}) . '</p>';
	}
	my $map = map_svg($d->{map});
	my $map_body;
	if ($map ne '') {
		$map_body = '<h2>Obstruction map</h2>'
		    . '<p class="note">Gray is unmeasured, blue is clear, red is blocked.</p>'
		    . $map;
	} else {
		$map_body = '<p class="note">No obstruction map stored.</p>';
	}
	my $ev = '';
	for my $row (@{ $d->{events} || [] }) {
		my $ts = _num($row->{ts});
		my $dur = _num($row->{duration_s});
		my $extra = defined $dur ? ' ' . sprintf('%.0fs', $dur) : '';
		$ev .= '<li><time>' . _he(defined $ts ? _fmt_clock($ts, $sec) : '')
		    . '</time> ' . _he(($row->{type} // '') . $extra);
		$ev .= ' ' . _he($row->{details}) if defined $row->{details} && $row->{details} ne '';
		$ev .= '</li>';
	}
	if ($ev eq '') {
		$ev = '<p class="note">No events in this window.</p>';
	} else {
		$ev = '<ul class="events">' . $ev . '</ul>';
	}
	my $loss = _num($latest->{ping_drop_rate});
	my $ob = _num($latest->{obstr_fraction});
	my $lat = _num($latest->{ping_latency_ms});
	my $view = ref $d->{view} eq 'HASH' ? $d->{view} : view_from();
	my $rev = defined $d->{rev} ? $d->{rev} : '';
	my $drawn = int($now);
	my $cadence = '<p class="note">Charts update every ' . int($view->{chart_s})
	    . 's, the same cadence as dish samples.</p>';
	my $cfghtml = '<section><h2>Configuration</h2><ul class="cfg">'
	    . '<li>Dish ' . _he($view->{dish_host}) . ':' . int($view->{dish_port})
	    . ', sample every ' . int($view->{sample_s}) . 's</li>'
	    . '<li>Charts update every ' . int($view->{chart_s}) . 's</li>'
	    . '<li>Obstruction map every ' . _span($view->{map_s}) . '</li>'
	    . '<li>Listen ' . _he($view->{listen}) . '</li>'
	    . '<li>Database ' . _he($view->{db}) . '</li>'
	    . '<li>Retention: raw ' . int($view->{raw_days})
	    . ' days, minutely ' . int($view->{minute_days})
	    . ' days, hourly ' . int($view->{hour_days}) . ' days</li>'
	    . '</ul></section>';
	return '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
	    . '<meta name="viewport" content="width=device-width, initial-scale=1">'
	    . live_tags($rev, $view->{chart_s})
	    . '<title>slmon</title><style>'
	    . 'body{font:16px/1.45 ui-sans-serif,sans-serif;margin:1.5rem auto;'
	    . 'max-width:64rem;padding:0 1rem;color:#1a1a1a;background:#fff}'
	    . 'header{display:flex;justify-content:space-between;align-items:flex-start;gap:1rem}'
	    . '.tools{display:flex;align-items:center;gap:0.5rem}'
	    . 'h1{font-size:1.4rem;font-weight:600;margin:0}'
	    . 'h2{font-size:1rem;font-weight:600;margin:1.2rem 0 0.35rem}'
	    . 'figure{margin:0.4rem 0 1rem}'
	    . '.who,.note,.id{color:#444;margin:0.2rem 0}'
	    . '.ranges{margin:0.8rem 0}'
	    . '.ranges a{margin-right:0.9rem}'
	    . '.ranges a[aria-current]{font-weight:600;color:inherit;text-decoration:none}'
	    . '.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(8.5rem,1fr));gap:0.6rem}'
	    . '.stat{border:1px solid #ddd;padding:0.5rem 0.7rem}'
	    . '.stat span{display:block;color:#444;font-size:0.85rem}'
	    . '.stat b{display:block;font-size:1.2rem;font-weight:600}'
	    . '.stale{color:#8a1f1f}'
	    . 'svg{display:block;width:100%;height:auto;background:#f7f7f7;border:1px solid #e4e4e4}'
	    . 'svg text{fill:#333;font-size:12px}'
	    . 'svg .empty{fill:#666}'
	    . 'svg line{stroke:#ddd}'
	    . 'svg .series{fill:none;stroke:#1d4e89;stroke-width:1.6}'
	    . 'svg circle.series{fill:#1d4e89}'
	    . 'svg .peak{fill:none;stroke:#9a3412;stroke-width:1;stroke-dasharray:3 3}'
	    . 'svg.obstruction{width:min(100%,28rem);background:#fff}'
	    . 'svg.obstruction .c{fill:#2f6f9f;stroke:none}'
	    . 'svg.obstruction .o{fill:#9a3412;stroke:none}'
	    . 'svg.obstruction .u{fill:#e6e6e6;stroke:none}'
	    . '.error{color:#8a1f1f}'
	    . '.cfg{padding-left:1.2rem;margin:0.4rem 0}'
	    . '.cfg li{margin:0.15rem 0}'
	    . 'button{font:inherit;padding:0.4rem 0.9rem}'
	    . '</style></head><body><header><div><h1>slmon</h1>'
	    . '<p class="who">Signed in as ' . _he($user) . '.</p></div>'
	    . '<div class="tools"><button type="button" id="install" hidden>Install</button>'
	    . '<form method="post" action="/logout"><button type="submit">Log out</button></form>'
	    . '</div></header>'
	    . '<div id="live" data-drawn="' . $drawn . '">'
	    . $err
	    . '<nav class="ranges">' . join('', @nav) . '</nav>'
	    . $cadence
	    . '<section id="overview"><h2>Overview</h2>'
	    . '<section class="stats">'
	    . _stat('Downlink', fmt_rate($latest->{downlink_bps}))
	    . _stat('Uplink', fmt_rate($latest->{uplink_bps}))
	    . _stat('Latency', defined $lat ? sprintf('%.0f ms', $lat) : 'n/a')
	    . _stat('Loss', defined $loss ? sprintf('%.1f%%', $loss * 100) : 'n/a')
	    . _stat('Obstruction', defined $ob ? sprintf('%.3f%%', $ob * 100) : 'n/a')
	    . _stat('Uptime', fmt_uptime($latest->{uptime_s}))
	    . '</section>'
	    . ($when ne '' ? '<p class="note' . $stale . '">Latest sample ' . _he($when)
		. ($stale ? ', stale' : '') . '</p>' : '')
	    . '</section>'
	    . '<section id="quality"><h2>Quality</h2>' . $quality . '</section>'
	    . '<section id="throughput"><h2>Throughput</h2>' . $throughput . '</section>'
	    . '<section id="dish"><h2>Dish</h2>'
	    . $id
	    . (@dish ? '<p class="note">' . _he(join(' · ', @dish)) . '</p>' : '')
	    . $alert
	    . $map_body
	    . '</section>'
	    . '<section id="history"><h2>History</h2>' . $ev . '</section>'
	    . $cfghtml
	    . '</div>'
	    . live_script()
	    . '</body></html>';
}

1;
