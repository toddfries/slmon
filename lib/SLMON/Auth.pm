package SLMON::Auth;

use strict;
use warnings;

use Digest::SHA qw(hmac_sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use POSIX ();

my $B64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

sub _urandom {
	my ($n) = @_;
	open my $fh, '<:raw', '/dev/urandom' or die "open /dev/urandom: $!\n";
	my $buf = '';
	while (length($buf) < $n) {
		my $got;
		my $r = read $fh, $got, $n - length($buf);
		die "read /dev/urandom: $!\n" if !defined $r;
		die "short read from /dev/urandom\n" if $r == 0;
		$buf .= $got;
	}
	close $fh;
	return $buf;
}

sub session_secret {
	my ($existing) = @_;
	return $existing if defined $existing && length $existing;
	return unpack('H*', _urandom(32));
}

sub password_ok {
	my ($pw) = @_;
	return defined $pw && length($pw) >= 8;
}

sub hash_password {
	my ($pw) = @_;
	die "password must be at least 8 characters\n" if !password_ok($pw);
	my $raw = _urandom(22);
	my $salt = '$2b$10$';
	for my $i (0 .. 21) {
		$salt .= substr($B64, ord(substr($raw, $i, 1)) % 64, 1);
	}
	my $hash = crypt($pw, $salt);
	die "crypt failed\n" if !defined $hash || $hash !~ /^\$2[aby]\$/;
	return $hash;
}

sub _ct_eq {
	my ($a, $b) = @_;
	return 0 if !defined $a || !defined $b;
	return 0 if length($a) != length($b);
	my $d = 0;
	for my $i (0 .. length($a) - 1) {
		$d |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
	}
	return $d == 0 ? 1 : 0;
}

sub verify_password {
	my ($pw, $hash) = @_;
	return 0 if !defined $pw || !defined $hash || $hash eq '';
	my $got = crypt($pw, $hash);
	return 0 if !defined $got;
	return _ct_eq($got, $hash);
}

sub _b64url {
	my ($raw) = @_;
	my $b = encode_base64($raw, '');
	$b =~ tr|+/|-_|;
	$b =~ s/=+\z//;
	return $b;
}

sub _b64url_dec {
	my ($b) = @_;
	$b =~ tr|-_|+/|;
	my $pad = (4 - length($b) % 4) % 4;
	$b .= '=' x $pad;
	my $raw = eval { decode_base64($b) };
	return undef if !defined $raw;
	return $raw;
}

sub sign_session {
	my ($user, $exp, $secret) = @_;
	die "session secret missing\n" if !defined $secret || $secret eq '';
	my $body = _b64url("$user:$exp");
	my $mac = hmac_sha256_hex($body, $secret);
	return "$body.$mac";
}

sub verify_session {
	my ($cookie, $secret, $now) = @_;
	return undef if !defined $cookie || !defined $secret;
	return undef if $cookie !~ /\A([A-Za-z0-9_-]+)\.([0-9a-f]{64})\z/;
	my ($body, $mac) = ($1, $2);
	my $expect = hmac_sha256_hex($body, $secret);
	return undef if !_ct_eq($mac, $expect);
	my $dec = _b64url_dec($body);
	return undef if !defined $dec || $dec !~ /\A([^:]+):(\d+)\z/;
	my ($user, $exp) = ($1, $2);
	return undef if $exp < $now;
	return $user;
}

sub rate_new {
	return {
		window => 300,
		limit  => 5,
		ip     => {},
	};
}

sub _prune {
	my ($st, $ip, $now) = @_;
	my $cut = $now - $st->{window};
	my @keep = grep { $_ >= $cut } @{ $st->{ip}{$ip} || [] };
	if (@keep) {
		$st->{ip}{$ip} = \@keep;
	} else {
		delete $st->{ip}{$ip};
	}
	return;
}

sub rate_fail {
	my ($st, $ip, $now) = @_;
	_prune($st, $ip, $now);
	push @{ $st->{ip}{$ip} }, $now;
	return scalar(@{ $st->{ip}{$ip} }) >= $st->{limit} ? 1 : 0;
}

sub rate_blocked {
	my ($st, $ip, $now) = @_;
	_prune($st, $ip, $now);
	return scalar(@{ $st->{ip}{$ip} || [] }) >= $st->{limit} ? 1 : 0;
}

sub rate_success {
	my ($st, $ip, $now) = @_;
	delete $st->{ip}{$ip};
	return;
}

sub _read_line {
	my ($in, $out, $echo) = @_;
	my $term;
	my $old;
	if (!$echo && -t $in) {
		$term = POSIX::Termios->new;
		$term->getattr(fileno($in));
		$old = $term->getlflag;
		$term->setlflag($old & ~POSIX::ECHO);
		$term->setattr(fileno($in), POSIX::TCSANOW);
	}
	my $line = <$in>;
	if ($term) {
		$term->setlflag($old);
		$term->setattr(fileno($in), POSIX::TCSANOW);
		print $out "\n" if defined $out;
	}
	return undef if !defined $line;
	chomp $line;
	return $line;
}

# Prompts on a terminal. A non-tty handle dies with the operator message.
sub prompt {
	my ($in, $out) = @_;
	$in  //= \*STDIN;
	$out //= \*STDOUT;
	my $prev = select $out;
	$| = 1;
	select $prev;
	if (!-t $in) {
		die "slmon: no admin password is set. Run `slmon init` or `slmon start` from a terminal.\n";
	}
	while (1) {
		print $out "Admin user [admin]: ";
		my $user = _read_line($in, $out, 1);
		die "slmon: end of input during admin prompt\n" if !defined $user;
		$user = 'admin' if $user eq '';
		print $out "Password: ";
		my $pw = _read_line($in, $out, 0);
		die "slmon: end of input during admin prompt\n" if !defined $pw;
		print $out "Repeat password: ";
		my $pw2 = _read_line($in, $out, 0);
		die "slmon: end of input during admin prompt\n" if !defined $pw2;
		if ($pw ne $pw2) {
			print $out "passwords do not match\n";
			next;
		}
		if (!password_ok($pw)) {
			print $out "password must be at least 8 characters\n";
			next;
		}
		return ($user, $pw);
	}
}

1;
