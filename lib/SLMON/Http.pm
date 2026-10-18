package SLMON::Http;

use strict;
use warnings;

use IO::Socket::INET;
use JSON::PP ();
use POSIX qw(strftime);
use SLMON ();
use SLMON::Auth;
use SLMON::Config;
use SLMON::Dash;
use SLMON::Imsg;

# Stat the page modules before pledge. After pledge this process cannot
# see a newer file, so the revision is the one it started with.
sub page_rev {
	my ($cfg) = @_;
	my $view = SLMON::Dash::view_from($cfg);
	my $buf = join "\n",
	    $view->{dish_host}, $view->{dish_port}, $view->{sample_s},
	    $view->{chart_s}, $view->{map_s}, $view->{db}, $view->{listen},
	    $view->{raw_days}, $view->{minute_days}, $view->{hour_days};
	for my $mod (qw(SLMON/Dash.pm SLMON/Http.pm SLMON/Config.pm)) {
		my $path = $INC{$mod} // '';
		my ($size, $mtime) = (0, 0);
		if ($path ne '' && -e $path) {
			($size, $mtime) = (stat $path)[7, 9];
		}
		$buf .= "\n$mod $size $mtime";
	}
	return _fnv1a($buf);
}

sub _fnv1a {
	my ($s) = @_;
	my $h = 2166136261;
	for my $c (unpack 'C*', $s) {
		$h ^= $c;
		$h = ($h * 16777619) & 0xffffffff;
	}
	return sprintf '%08x', $h;
}

sub _page_bits {
	my ($ctx) = @_;
	my $view = SLMON::Dash::view_from($ctx->{cfg});
	my $rev = defined $ctx->{rev} ? $ctx->{rev} : '';
	return ($rev, $view);
}

sub _parse_form {
	my ($s) = @_;
	$s //= '';
	my %q;
	for my $pair (split /&/, $s) {
		my ($k, $v) = split /=/, $pair, 2;
		next if !defined $k;
		$v //= '';
		for ($k, $v) {
			tr/+/ /;
			s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
		}
		$q{$k} = $v;
	}
	return \%q;
}

sub _cookie {
	my ($hdr, $name) = @_;
	return undef if !defined $hdr;
	for my $part (split /;\s*/, $hdr) {
		my ($k, $v) = split /=/, $part, 2;
		return $v if defined $k && $k eq $name;
	}
	return undef;
}

sub read_request {
	my ($sock) = @_;
	local $SIG{ALRM} = sub { die "timeout\n" };
	alarm 5;
	my $buf = '';
	while ($buf !~ /\r\n\r\n/) {
		my $n = sysread $sock, $buf, 4096, length($buf);
		alarm 0;
		return undef if !defined $n || $n == 0;
		alarm 5;
		die "request too large\n" if length($buf) > 65536;
	}
	my ($head, $rest) = split /\r\n\r\n/, $buf, 2;
	$rest //= '';
	my @lines = split /\r\n/, $head;
	my $reqline = shift @lines // '';
	my ($method, $target, undef) = split / /, $reqline, 3;
	my %hdr;
	for my $line (@lines) {
		my ($k, $v) = split /:\s*/, $line, 2;
		$hdr{lc $k} = $v if defined $k;
	}
	my $len = $hdr{'content-length'} // 0;
	$len = 0 if $len !~ /\A[0-9]+\z/;
	while (length($rest) < $len) {
		my $n = sysread $sock, $rest, $len - length($rest), length($rest);
		last if !defined $n || $n == 0;
	}
	alarm 0;
	my ($path, $qs) = split /\?/, $target // '', 2;
	return {
		method  => $method // '',
		path    => $path // '',
		query   => _parse_form($qs),
		headers => \%hdr,
		body    => substr($rest, 0, $len),
	};
}

my %REASON = (
	200 => 'OK',
	303 => 'See Other',
	400 => 'Bad Request',
	401 => 'Unauthorized',
	404 => 'Not Found',
	405 => 'Method Not Allowed',
	429 => 'Too Many Requests',
	500 => 'Internal Server Error',
);

sub _he {
	my ($s) = @_;
	$s //= '';
	$s =~ s/&/&amp;/g;
	$s =~ s/</&lt;/g;
	$s =~ s/>/&gt;/g;
	$s =~ s/"/&quot;/g;
	return $s;
}

sub _response {
	my ($code, $type, $body, $extra) = @_;
	$body //= '';
	my $reason = $REASON{$code} // 'Error';
	my $hdr = "HTTP/1.0 $code $reason\r\n"
	    . "Content-Type: $type\r\n"
	    . 'Content-Length: ' . length($body) . "\r\n"
	    . "Connection: close\r\n";
	$hdr .= $extra if defined $extra && $extra ne '';
	return $hdr . "\r\n" . $body;
}

sub _json_response {
	my ($code, $obj, $extra) = @_;
	return _response($code, 'application/json', SLMON::json_encode($obj), $extra);
}

sub _html_response {
	my ($code, $html, $extra) = @_;
	my $hdr = "Cache-Control: no-store\r\n";
	$hdr .= $extra if defined $extra && $extra ne '';
	return _response($code, 'text/html; charset=utf-8', $html, $hdr);
}

sub _redirect {
	my ($loc, $extra) = @_;
	my $body = '<!DOCTYPE html><html><head><meta charset="utf-8">'
	    . '<title>slmon</title></head><body><a href="'
	    . _he($loc) . '">continue</a></body></html>';
	my $hdr = "Location: $loc\r\n";
	$hdr .= $extra if defined $extra && $extra ne '';
	return _html_response(303, $body, $hdr);
}

sub _page {
	my ($title, $inner, $rev, $refresh_s) = @_;
	return '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
	    . '<meta name="viewport" content="width=device-width, initial-scale=1">'
	    . SLMON::Dash::live_tags($rev, $refresh_s)
	    . '<title>' . _he($title) . '</title><style>'
	    . 'body{font:16px/1.45 ui-sans-serif,sans-serif;margin:2rem auto;'
	    . 'max-width:32rem;padding:0 1rem;color:#1a1a1a;background:#fff}'
	    . 'h1{font-size:1.4rem;font-weight:600;margin:0 0 1rem}'
	    . 'label{display:block;margin:0.9rem 0}'
	    . 'input{display:block;width:100%;box-sizing:border-box;margin-top:0.25rem;'
	    . 'font:inherit;padding:0.4rem 0.5rem}'
	    . 'button{font:inherit;padding:0.4rem 0.9rem}'
	    . '.error{color:#8a1f1f}'
	    . 'ul{padding-left:1.2rem}li{margin:0.25rem 0}'
	    . '</style></head><body>' . $inner
	    . SLMON::Dash::live_script()
	    . '</body></html>';
}

sub _login_page {
	my ($user, $error, $rev, $refresh_s) = @_;
	my $err = '';
	if (defined $error && $error ne '') {
		$err = '<p class="error">' . _he($error) . '</p>';
	}
	return _page('slmon login',
	    '<h1>slmon</h1>' . $err
	    . '<form method="post" action="/login">'
	    . '<label for="user">User <input id="user" name="user" value="' . _he($user) . '"'
	    . ' autocomplete="username" autofocus></label>'
	    . '<label for="password">Password <input id="password" type="password" name="password"'
	    . ' autocomplete="current-password"></label>'
	    . '<button type="submit">Log in</button></form>',
	    $rev, $refresh_s);
}

sub _authed {
	my ($req, $ctx) = @_;
	my $cookie = _cookie($req->{headers}{cookie}, 'slmon_session');
	my $user = SLMON::Auth::verify_session($cookie, $ctx->{secret}, $ctx->{now} // time);
	return undef if !defined $user || !defined $ctx->{admin} || $user ne $ctx->{admin};
	return $user;
}

sub _login_fields {
	my ($req) = @_;
	my $form;
	my $ct = $req->{headers}{'content-type'} // '';
	if ($ct =~ /json/) {
		$form = eval { SLMON::json_decode($req->{body}) } || {};
	} else {
		$form = _parse_form($req->{body});
	}
	my $user = $form->{user} // $form->{username} // '';
	my $pw = $form->{password} // '';
	return ($user, $pw);
}

# 200 and a token, or 401/429. The last value is the user field from the body.
sub _authenticate {
	my ($req, $ctx) = @_;
	my $ip = $ctx->{ip} // '0';
	my $now = $ctx->{now} // time;
	my ($user, $pw) = _login_fields($req);
	if (SLMON::Auth::rate_blocked($ctx->{rate}, $ip, $now)) {
		return (429, undef, undef, $user);
	}
	my $ok = _db_login($ctx->{imsg}, $user, $pw);
	if (!$ok) {
		my $blocked = SLMON::Auth::rate_fail($ctx->{rate}, $ip, $now);
		return ($blocked ? 429 : 401, undef, undef, $user);
	}
	SLMON::Auth::rate_success($ctx->{rate}, $ip, $now);
	my $exp = $now + 12 * 3600;
	my $tok = SLMON::Auth::sign_session($user, $exp, $ctx->{secret});
	return (200, $user, $tok, $user);
}

sub _session_cookie {
	my ($token) = @_;
	return "Set-Cookie: slmon_session=$token; HttpOnly; SameSite=Lax; Path=/; Max-Age=43200\r\n";
}

sub _clear_cookie {
	return "Set-Cookie: slmon_session=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0\r\n";
}

sub _db_query {
	my ($imsg, $q) = @_;
	$imsg->send(SLMON::IMSG_QUERY, SLMON::json_encode($q));
	my @rows;
	while (1) {
		my $m = $imsg->recv;
		die "db closed during query\n" if !$m;
		if ($m->{type} == SLMON::IMSG_ROWS) {
			my $doc = SLMON::json_decode($m->{data}) || {};
			push @rows, @{ $doc->{rows} || [] };
		} elsif ($m->{type} == SLMON::IMSG_QUERY_DONE) {
			my $doc = SLMON::json_decode($m->{data}) || {};
			die $doc->{error} if $doc->{error};
			last;
		} else {
			die "unexpected imsg $m->{type} during query\n";
		}
	}
	return \@rows;
}

sub _dash_load {
	my ($ctx, $range) = @_;
	return $ctx->{dash}->($range) if ref $ctx->{dash} eq 'CODE';
	my $now = $ctx->{now} // time;
	my $sec = SLMON::Dash::range_seconds($range);
	my $from = $now - $sec;
	my $table = SLMON::Dash::series_table($range);
	my $series = _db_query($ctx->{imsg}, {
		op => 'raw', table => $table, from => $from, to => $now,
		limit => 20000, order => 'asc',
	});
	# Obstruction and jitter live on the rollup once that tier has them.
	# Status polls remain the obstruction source for 1h, and for a longer
	# range whose rollup does not have a fraction yet.
	my $obstruction = $series;
	my $obstr_from = 'series';
	if ($table ne 'metrics' && !SLMON::Dash::tier_has_obstr($series)) {
		$obstruction = _db_query($ctx->{imsg}, {
			op => 'raw', table => 'metrics', from => $from, to => $now,
			limit => 20000, order => 'asc',
		});
		$obstr_from = 'metrics';
	}
	my $jitter = $series;
	if ($table eq 'metrics') {
		$jitter = _db_query($ctx->{imsg}, {
			op => 'raw', table => 'metrics_minutely', from => $from, to => $now,
			limit => 20000, order => 'asc',
		});
	}
	if (($ctx->{log_level} // '') eq 'debug') {
		warn "slmon: dash range=$range table=$table rows=" . scalar(@$series)
		    . " obstr=$obstr_from obstr_rows=" . scalar(@$obstruction)
		    . " jitter_rows=" . scalar(@$jitter) . "\n";
	}
	my $latest = _db_query($ctx->{imsg}, { op => 'latest', table => 'metrics' });
	my $info = _db_query($ctx->{imsg}, { op => 'latest', table => 'dish_info' });
	my $events = _db_query($ctx->{imsg}, {
		op => 'raw', table => 'events', from => $from, to => $now,
		limit => 30, order => 'desc',
	});
	my $map = _db_query($ctx->{imsg}, { op => 'latest', table => 'obstruction_map' });
	return {
		series       => $series,
		obstruction  => $obstruction,
		jitter       => $jitter,
		latest       => $latest->[0],
		info         => $info->[0],
		events       => $events,
		map          => $map->[0],
		window_from  => $from,
		window_to    => $now,
	};
}

sub _db_login {
	my ($imsg, $user, $pw) = @_;
	$imsg->send(SLMON::IMSG_LOGIN, SLMON::json_encode({
		user => $user, password => $pw,
	}));
	my $m = $imsg->recv;
	die "db closed during login\n" if !$m || $m->{type} != SLMON::IMSG_LOGIN_RESULT;
	my $doc = SLMON::json_decode($m->{data}) || {};
	return $doc->{ok} ? 1 : 0;
}

sub respond {
	my ($req, $ctx) = @_;
	my $method = $req->{method};
	my $path = $req->{path};
	if ($method eq 'GET' && $path eq '/health') {
		my $rev = defined $ctx->{rev} ? $ctx->{rev} : '';
		return _json_response(200, { ok => JSON::PP::true, rev => $rev },
		    "Cache-Control: no-store\r\n");
	}
	if ($method eq 'GET' && $path eq '/login') {
		return _redirect('/') if defined _authed($req, $ctx);
		my ($rev, $view) = _page_bits($ctx);
		return _html_response(200, _login_page('', '', $rev, $view->{chart_s}));
	}
	if ($method eq 'GET' && $path eq '/') {
		my $user = _authed($req, $ctx);
		return _redirect('/login') if !defined $user;
		my $range = SLMON::Dash::range_name($req->{query}{range});
		my $data = eval { _dash_load($ctx, $range) };
		if ($@) {
			$data = { error => 'The database did not answer.' };
		}
		$data->{user} = $user;
		$data->{range} = $range;
		$data->{now} = $ctx->{now} // time;
		my ($rev, $view) = _page_bits($ctx);
		$data->{view} = $view;
		$data->{rev} = $rev;
		return _html_response(200, SLMON::Dash::page($data));
	}
	if ($method eq 'POST' && $path eq '/logout') {
		return _redirect('/login', _clear_cookie());
	}
	if ($method eq 'POST' && $path eq '/api/logout') {
		return _json_response(200, { ok => JSON::PP::true }, _clear_cookie());
	}
	if ($method eq 'POST' && ($path eq '/api/login' || $path eq '/login')) {
		my ($code, $user, $tok, $tried) = _authenticate($req, $ctx);
		if ($path eq '/login') {
			if ($code == 200) {
				return _redirect('/', _session_cookie($tok));
			}
			my $msg = $code == 429
			    ? 'Too many attempts. Wait five minutes and try again.'
			    : 'User or password is wrong.';
			my ($rev, $view) = _page_bits($ctx);
			return _html_response($code, _login_page($tried, $msg, $rev, $view->{chart_s}));
		}
		if ($code == 200) {
			return _json_response(200, { ok => JSON::PP::true, user => $user },
			    _session_cookie($tok));
		}
		return _json_response($code, {
			error => $code == 429 ? 'rate limit' : 'unauthorized',
		});
	}
	if ($method eq 'GET' && $path =~ m{\A/api/(latest|raw)/([A-Za-z0-9_]+)\z}) {
		my ($op, $table) = ($1, $2);
		my $cookie = _cookie($req->{headers}{cookie}, 'slmon_session');
		my $user = SLMON::Auth::verify_session($cookie, $ctx->{secret}, $ctx->{now} // time);
		if (!defined $user || $user ne $ctx->{admin}) {
			return _json_response(401, { error => 'unauthorized' });
		}
		my $q = { op => $op, table => $table };
		if ($op eq 'raw') {
			$q->{from} = $req->{query}{from};
			$q->{to} = $req->{query}{to};
			$q->{limit} = $req->{query}{limit};
			$q->{order} = $req->{query}{order} if defined $req->{query}{order};
		}
		my $rows = eval { _db_query($ctx->{imsg}, $q) };
		if ($@) {
			my $err = $@;
			return _json_response(400, { error => "$err" }) if $err =~ /unknown table|limit|order|time bound/;
			die $err;
		}
		return _json_response(200, { rows => $rows });
	}
	if ($path =~ m{\A/api/}) {
		return _json_response(404, { error => 'not found' });
	}
	return _json_response(404, { error => 'not found' });
}

sub _handle_client {
	my ($cli, $imsg, $secret, $admin, $rate, $cfg) = @_;
	my $req = eval { read_request($cli) };
	if (!$req) {
		return;
	}
	my $ip = $cli->peerhost // '0';
	my $resp = eval {
		respond($req, {
			imsg   => $imsg,
			secret => $secret,
			admin  => $admin,
			rate   => $rate,
			ip        => $ip,
			now       => time,
			log_level => $cfg->{log_level} // 'info',
			cfg       => $cfg,
			rev       => $cfg->{page_rev} // '',
		});
	};
	if ($@) {
		warn "slmon: http: $@";
		$resp = _json_response(500, { error => 'internal' });
	}
	syswrite $cli, $resp if defined $resp;
	return;
}

sub run {
	my ($sock, $listen, $cfg) = @_;
	SLMON::proc_title('http');
	$SIG{PIPE} = 'IGNORE';
	$SIG{TERM} = sub { exit 0 };
	my $imsg = SLMON::Imsg->open(fileno($sock));
	my $hello = $imsg->recv;
	die "slmon: http: no config from db\n"
	    if !$hello || $hello->{type} != SLMON::IMSG_CONFIG;
	my $doc = SLMON::json_decode($hello->{data}) || {};
	my $secret = $doc->{session_secret} or die "slmon: http: session secret missing\n";
	my $admin = $doc->{admin_user} // 'admin';
	$cfg->{page_rev} = page_rev($cfg);
	# localtime reads the zone file. Do it before the pledge locks the filesystem.
	strftime('%H:%M', localtime($^T));
	require OpenBSD::Pledge;
	OpenBSD::Pledge::pledge('inet')
	    or die "slmon: http pledge: $!\n";
	my $rate = SLMON::Auth::rate_new();
	while (1) {
		my $rin = '';
		vec($rin, fileno($listen), 1) = 1;
		vec($rin, $imsg->fd, 1) = 1;
		my $n = select($rin, undef, undef, 1);
		if (vec($rin, $imsg->fd, 1)) {
			my $r = $imsg->read_more;
			exit 0 if defined $r && $r == 0;
			while (my $m = $imsg->get) {
				exit 0 if $m->{type} == SLMON::IMSG_SHUTDOWN;
			}
		}
		next if !$n || !vec($rin, fileno($listen), 1);
		my $cli = $listen->accept;
		next if !$cli;
		eval { _handle_client($cli, $imsg, $secret, $admin, $rate, $cfg) };
		warn "slmon: http client: $@" if $@;
		close $cli;
	}
}

1;
