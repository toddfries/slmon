package SLMON::Http;

use strict;
use warnings;

use IO::Socket::INET;
use JSON::PP ();
use SLMON ();
use SLMON::Auth;
use SLMON::Imsg;

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

sub _json_response {
	my ($code, $obj, $extra) = @_;
	my %reason = (
		200 => 'OK',
		400 => 'Bad Request',
		401 => 'Unauthorized',
		404 => 'Not Found',
		405 => 'Method Not Allowed',
		429 => 'Too Many Requests',
		500 => 'Internal Server Error',
	);
	my $body = SLMON::json_encode($obj);
	my $reason = $reason{$code} // 'Error';
	my $hdr = "HTTP/1.0 $code $reason\r\n"
	    . "Content-Type: application/json\r\n"
	    . 'Content-Length: ' . length($body) . "\r\n"
	    . "Connection: close\r\n";
	$hdr .= $extra if defined $extra && $extra ne '';
	return $hdr . "\r\n" . $body;
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
		return _json_response(200, { ok => JSON::PP::true });
	}
	if ($method eq 'POST' && $path eq '/api/logout') {
		return _json_response(200, { ok => JSON::PP::true }, _clear_cookie());
	}
	if ($method eq 'POST' && $path eq '/api/login') {
		my $ip = $ctx->{ip} // '0';
		my $now = $ctx->{now} // time;
		if (SLMON::Auth::rate_blocked($ctx->{rate}, $ip, $now)) {
			return _json_response(429, { error => 'rate limit' });
		}
		my $form;
		my $ct = $req->{headers}{'content-type'} // '';
		if ($ct =~ /json/) {
			$form = eval { SLMON::json_decode($req->{body}) } || {};
		} else {
			$form = _parse_form($req->{body});
		}
		my $user = $form->{user} // $form->{username} // '';
		my $pw = $form->{password} // '';
		my $ok = _db_login($ctx->{imsg}, $user, $pw);
		if (!$ok) {
			my $blocked = SLMON::Auth::rate_fail($ctx->{rate}, $ip, $now);
			return _json_response($blocked ? 429 : 401, { error => 'unauthorized' });
		}
		SLMON::Auth::rate_success($ctx->{rate}, $ip, $now);
		my $exp = $now + 12 * 3600;
		my $tok = SLMON::Auth::sign_session($user, $exp, $ctx->{secret});
		return _json_response(200, { ok => JSON::PP::true, user => $user },
		    _session_cookie($tok));
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
	my ($cli, $imsg, $secret, $admin, $rate) = @_;
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
			ip     => $ip,
			now    => time,
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
		eval { _handle_client($cli, $imsg, $secret, $admin, $rate) };
		warn "slmon: http client: $@" if $@;
		close $cli;
	}
}

1;
