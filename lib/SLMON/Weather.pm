package SLMON::Weather;

use strict;
use warnings;

use SLMON ();

# Thunderstorm 95/96/99, heavy snow 75/86, wind at least 50 km/h.
sub warning {
	my (%in) = @_;
	my @parts;
	my $code = $in{wmo_code};
	if (defined $code && ($code == 95 || $code == 96 || $code == 99)) {
		push @parts, 'thunderstorm';
	}
	if (defined $code && ($code == 75 || $code == 86)) {
		push @parts, 'heavy snow';
	}
	if (defined $in{wind_kmh} && $in{wind_kmh} >= 50) {
		push @parts, 'high wind';
	}
	return @parts ? join(', ', @parts) : undef;
}

sub _query {
	my ($lat, $lon) = @_;
	my $q = join '&',
	    "latitude=$lat",
	    "longitude=$lon",
	    'current=temperature_2m,wind_speed_10m,weather_code,precipitation,relative_humidity_2m',
	    'wind_speed_unit=kmh',
	    'timezone=UTC';
	return $q;
}

sub fetch {
	my ($lat, $lon) = @_;
	require IO::Socket::SSL;
	my $sock = IO::Socket::SSL->new(
		PeerHost        => 'api.open-meteo.com',
		PeerPort        => 443,
		SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER(),
		SSL_hostname    => 'api.open-meteo.com',
		Timeout         => 10,
	);
	die "slmon: weather connect: $!\n" if !$sock;
	my $path = '/v1/forecast?' . _query($lat, $lon);
	print $sock "GET $path HTTP/1.0\r\nHost: api.open-meteo.com\r\nConnection: close\r\n\r\n"
	    or die "slmon: weather write: $!\n";
	local $/;
	my $resp = <$sock> // '';
	close $sock;
	my ($body) = $resp =~ /\r\n\r\n(.*)\z/s;
	die "slmon: weather: empty response\n" if !defined $body || $body eq '';
	my $doc = SLMON::json_decode($body);
	my $cur = $doc->{current} || {};
	my $wind = $cur->{wind_speed_10m};
	my $code = $cur->{weather_code};
	return {
		ts              => time,
		temp_c          => $cur->{temperature_2m},
		wind_kmh        => $wind,
		wmo_code        => $code,
		precipitation_mm => $cur->{precipitation},
		visibility_m    => undef,
		humidity        => $cur->{relative_humidity_2m},
		warning         => warning(wmo_code => $code, wind_kmh => $wind),
	};
}

sub _wait {
	my ($imsg, $seconds) = @_;
	my $deadline = time + $seconds;
	while (1) {
		while (my $m = $imsg->get) {
			return 0 if $m->{type} == SLMON::IMSG_SHUTDOWN;
		}
		my $left = $deadline - time;
		return 1 if $left <= 0;
		my $rin = '';
		vec($rin, $imsg->fd, 1) = 1;
		my $n = select($rin, undef, undef, $left);
		next if !$n;
		my $r = $imsg->read_more;
		return 0 if defined $r && $r == 0;
	}
}

sub run {
	my ($sock, $cfg) = @_;
	SLMON::proc_title('weather');
	require SLMON::Imsg;
	return if $cfg->{latitude} eq '' || $cfg->{longitude} eq '';
	require IO::Socket::SSL;
	my $imsg = SLMON::Imsg->open(fileno($sock));
	require OpenBSD::Pledge;
	require OpenBSD::Unveil;
	for my $path ('/etc/ssl', '/etc/resolv.conf', '/etc/hosts') {
		next if !-e $path;
		my $perm = -d $path ? 'r' : 'r';
		OpenBSD::Unveil::unveil($path, $perm)
		    or die "slmon: weather unveil $path: $!\n";
	}
	OpenBSD::Unveil::unveil()
	    or die "slmon: weather unveil lock: $!\n";
	OpenBSD::Pledge::pledge(qw(inet dns rpath))
	    or die "slmon: weather pledge: $!\n";
	while (1) {
		my $row = eval { fetch($cfg->{latitude}, $cfg->{longitude}) };
		if ($@) {
			warn "slmon: weather: $@";
		} elsif ($row) {
			$imsg->send(SLMON::IMSG_WEATHER, SLMON::json_encode($row));
		}
		last if !_wait($imsg, 600);
	}
	exit 0;
}

1;
