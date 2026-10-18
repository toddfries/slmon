use strict;
use warnings;

# Private PostgreSQL cluster on a local socket. Trust auth, no TCP listen.
sub pg_up {
	my ($base) = @_;
	my $initdb = '/usr/local/bin/initdb';
	my $pg_ctl = '/usr/local/bin/pg_ctl';
	my $createdb = '/usr/local/bin/createdb';
	die "postgresql-server is required (initdb not found)\n" if !-x $initdb;
	eval { require DBD::Pg; 1 } or die "p5-DBD-Pg is required\n";
	my $data = "$base/pg";
	local $ENV{LC_ALL} = 'C';
	local $ENV{LC_CTYPE} = 'C';
	my $rc = system($initdb, '-D', $data, '--locale=C', '--encoding=UTF8',
	    '--auth=trust', '--username=slmon');
	die "initdb failed\n" if $rc != 0;
	$rc = system($pg_ctl, '-D', $data, '-w', '-l', "$base/pg.log",
	    '-o', "-c listen_addresses='' -c unix_socket_directories=$data",
	    'start');
	die "pg_ctl start failed\n" if $rc != 0;
	$rc = system($createdb, '-h', $data, '-U', 'slmon', 'slmon');
	if ($rc != 0) {
		die "createdb failed\n" if !-e "$data/.s.PGSQL.5432";
	}
	return sub {
		system($pg_ctl, '-D', $data, '-w', '-m', 'fast', 'stop');
	};
}

1;
