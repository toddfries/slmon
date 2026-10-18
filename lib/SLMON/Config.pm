package SLMON::Config;

use strict;
use warnings;

use SLMON ();

my %DEFAULT = (
	listen                  => '127.0.0.1:8080',
	dish_host               => '192.168.100.1',
	dish_interval_s         => 30,
	db                      => 'sqlite',
	pg_host                 => '',
	pg_port                 => '',
	pg_db                   => '',
	pg_user                 => '',
	pg_password             => '',
	latitude                => '',
	longitude               => '',
	raw_retention_days      => 90,
	minutely_retention_days => 730,
	hourly_rollup_days      => 365,
	rollup_interval_s       => 60,
	ping_targets            => '1.1.1.1,8.8.8.8',
	ping_interval_s         => 10,
	disconnect_failures     => 3,
	spike_ms                => 200,
	spike_min_s             => 30,
	log_level               => 'info',
);

my %INT_KEY = map { $_ => 1 } qw(
    dish_interval_s raw_retention_days minutely_retention_days
    hourly_rollup_days rollup_interval_s ping_interval_s
    disconnect_failures spike_ms spike_min_s
);

sub parse {
	my ($text) = @_;
	$text //= '';
	my %cfg = %DEFAULT;
	my $n = 0;
	for my $line (split /\n/, $text) {
		$n++;
		next if $line =~ /\A\s*(?:#|\z)/;
		if ($line !~ /\A\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*\z/) {
			die "slmon: config line $n is not key = value\n";
		}
		my ($k, $v) = ($1, $2);
		die "slmon: unknown config key $k\n" if !exists $DEFAULT{$k};
		$cfg{$k} = $v;
	}
	die "slmon: db must be sqlite or pg\n" if $cfg{db} ne 'sqlite' && $cfg{db} ne 'pg';
	if ($cfg{db} eq 'pg' && $cfg{pg_db} eq '') {
		die "slmon: db = pg requires pg_db\n";
	}
	for my $k (keys %INT_KEY) {
		die "slmon: $k must be an integer\n" if $cfg{$k} !~ /\A[0-9]+\z/;
		$cfg{$k} = int($cfg{$k});
	}
	die "slmon: dish_interval_s must be at least " . SLMON::MIN_POLL_S . "\n"
	    if $cfg{dish_interval_s} < SLMON::MIN_POLL_S;
	die "slmon: rollup_interval_s must be at least 1\n" if $cfg{rollup_interval_s} < 1;
	die "slmon: log_level must be info or debug\n"
	    if $cfg{log_level} ne 'info' && $cfg{log_level} ne 'debug';
	if ($cfg{latitude} ne '' || $cfg{longitude} ne '') {
		die "slmon: latitude and longitude must both be set\n"
		    if $cfg{latitude} eq '' || $cfg{longitude} eq '';
		die "slmon: latitude is not a number\n" if $cfg{latitude} !~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;
		die "slmon: longitude is not a number\n" if $cfg{longitude} !~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;
	}
	return \%cfg;
}

sub load_file {
	my ($path) = @_;
	my $text = '';
	if (defined $path && $path ne '') {
		open my $fh, '<', $path or die "slmon: $path: $!\n";
		local $/;
		$text = <$fh> // '';
		close $fh;
	}
	return parse($text);
}

# host, port. Port stays 9200 unless dish_host is written as host:port.
sub dish_endpoint {
	my ($cfg) = @_;
	my $host = $cfg->{dish_host};
	my $port = 9200;
	if ($host =~ /\A(.+):([0-9]+)\z/) {
		$host = $1;
		$port = int($2);
	}
	return ($host, $port);
}

sub listen_endpoint {
	my ($cfg) = @_;
	my $spec = $cfg->{listen};
	die "slmon: listen must be host:port\n" if $spec !~ /\A(.+):([0-9]+)\z/;
	return ($1, int($2));
}

sub apply_paths {
	my ($cfg, %opt) = @_;
	if (defined $opt{listen} && $opt{listen} ne '') {
		$cfg->{listen} = $opt{listen};
		listen_endpoint($cfg);
	}
	my $db_path = $opt{db_path};
	$db_path = $ENV{SLMON_DB} if !defined $db_path || $db_path eq '';
	$db_path = SLMON::default_db_path($opt{root}) if !defined $db_path || $db_path eq '';
	$cfg->{db_path} = $db_path;
	if ($db_path =~ m{\A(.+)/[^/]+\z}) {
		$cfg->{state_dir} = $1;
	} else {
		$cfg->{state_dir} = '.';
	}
	return $cfg;
}

1;
