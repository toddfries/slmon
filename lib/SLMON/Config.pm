package SLMON::Config;

use strict;
use warnings;

use SLMON ();

my %DEFAULT = (
	listen                  => '127.0.0.1:8080',
	db_path                 => '/var/sl/sl.db',
	dish_host               => '192.168.100.1',
	dish_interval_s         => 30,
	dish_client             => 'perl',
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
	my @listen_lines;
	my $n = 0;
	for my $line (split /\n/, $text) {
		$n++;
		next if $line =~ /\A\s*(?:#|\z)/;
		if ($line !~ /\A\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*\z/) {
			die SLMON::err("config line $n is not key = value");
		}
		my ($k, $v) = ($1, $2);
		if ($k eq 'listen') {
			push @listen_lines, $v;
			next;
		}
		die SLMON::err("unknown config key $k") if !exists $DEFAULT{$k};
		$cfg{$k} = $v;
	}
	die SLMON::err('db must be sqlite or pg') if $cfg{db} ne 'sqlite' && $cfg{db} ne 'pg';
	if ($cfg{db} eq 'pg' && $cfg{pg_db} eq '') {
		die SLMON::err('db = pg requires pg_db');
	}
	for my $k (keys %INT_KEY) {
		die SLMON::err("$k must be an integer") if $cfg{$k} !~ /\A[0-9]+\z/;
		$cfg{$k} = int($cfg{$k});
	}
	die SLMON::err('dish_interval_s must be at least ' . SLMON::MIN_POLL_S)
	    if $cfg{dish_interval_s} < SLMON::MIN_POLL_S;
	die SLMON::err('rollup_interval_s must be at least 1') if $cfg{rollup_interval_s} < 1;
	die SLMON::err('log_level must be info or debug')
	    if $cfg{log_level} ne 'info' && $cfg{log_level} ne 'debug';
	die SLMON::err('dish_client must be perl or xs')
	    if $cfg{dish_client} ne 'perl' && $cfg{dish_client} ne 'xs';
	if ($cfg{latitude} ne '' || $cfg{longitude} ne '') {
		die SLMON::err('latitude and longitude must both be set')
		    if $cfg{latitude} eq '' || $cfg{longitude} eq '';
		die SLMON::err('latitude is not a number') if $cfg{latitude} !~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;
		die SLMON::err('longitude is not a number') if $cfg{longitude} !~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;
	}
	$cfg{db_path} = '/var/sl/sl.db' if !defined $cfg{db_path} || $cfg{db_path} eq '';
	@listen_lines = ($DEFAULT{listen}) if !@listen_lines;
	my @canon;
	for my $spec (@listen_lines) {
		my ($host, $port) = _split_listen($spec);
		push @canon, _canon_listen($host, $port);
	}
	$cfg{listens} = \@canon;
	$cfg{listen} = $canon[0];
	return \%cfg;
}

sub load_file {
	my ($path) = @_;
	my $text = '';
	if (defined $path && $path ne '') {
		open my $fh, '<', $path or die SLMON::err("$path: $!");
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

# host:port, or [ipv6]:port. The port is 0 or at least 1024.
sub _split_listen {
	my ($spec) = @_;
	$spec //= '';
	my ($host, $port);
	if ($spec =~ /\A\[([^\]]+)\]:([0-9]+)\z/) {
		($host, $port) = ($1, int($2));
	} elsif ($spec =~ /\A(.+):([0-9]+)\z/) {
		($host, $port) = ($1, int($2));
	} else {
		die SLMON::err('listen must be host:port');
	}
	die SLMON::err('listen must be host:port') if $host eq '';
	die SLMON::err('listen port must be 0 or at least 1024')
	    if $port != 0 && $port < 1024;
	return ($host, $port);
}

sub _canon_listen {
	my ($host, $port) = @_;
	return "[$host]:$port" if $host =~ /:/;
	return "$host:$port";
}

sub shown_listen {
	my ($host, $port) = @_;
	return _canon_listen($host, $port);
}

sub listen_endpoint {
	my ($cfg) = @_;
	my ($host, $port) = _split_listen($cfg->{listen});
	return ($host, $port);
}

# [host, port, label] for every listen line, in file order.
sub listen_endpoints {
	my ($cfg) = @_;
	my @specs;
	if (ref $cfg->{listens} eq 'ARRAY' && @{ $cfg->{listens} }) {
		@specs = @{ $cfg->{listens} };
	} elsif (defined $cfg->{listen} && $cfg->{listen} ne '') {
		@specs = ($cfg->{listen});
	}
	die SLMON::err('listen must be host:port') if !@specs;
	my @out;
	for my $spec (@specs) {
		my ($host, $port) = _split_listen($spec);
		push @out, [$host, $port, _canon_listen($host, $port)];
	}
	return @out;
}

sub apply_paths {
	my ($cfg, %opt) = @_;
	if (defined $opt{listen} && $opt{listen} ne '') {
		my ($host, $port) = _split_listen($opt{listen});
		my $label = _canon_listen($host, $port);
		$cfg->{listen} = $label;
		$cfg->{listens} = [$label];
	}
	my $db_path = $opt{db_path};
	$db_path = $ENV{SLMON_DB} if !defined $db_path || $db_path eq '';
	if (!defined $db_path || $db_path eq '') {
		$db_path = $cfg->{db_path} || SLMON::default_db_path();
	}
	$cfg->{db_path} = $db_path;
	if ($db_path =~ m{\A(.+)/[^/]+\z}) {
		$cfg->{state_dir} = $1;
	} else {
		$cfg->{state_dir} = '.';
	}
	return $cfg;
}

1;
