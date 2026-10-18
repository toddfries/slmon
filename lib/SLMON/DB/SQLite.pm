package SLMON::DB::SQLite;

use strict;
use warnings;

use DBI ();
use DBD::SQLite;

sub types {
	return {
		id   => 'INTEGER PRIMARY KEY AUTOINCREMENT',
		big  => 'BIGINT',
		real => 'REAL',
		blob => 'BLOB',
		int  => 'INTEGER',
		text => 'TEXT',
	};
}

sub connect {
	my ($cfg, %opt) = @_;
	my $path = $cfg->{db_path} or die "slmon: sqlite path is not set\n";
	my %attr = (
		RaiseError => 1,
		PrintError => 0,
		AutoCommit => 1,
	);
	if ($opt{readonly}) {
		$attr{sqlite_open_flags} = DBD::SQLite::OPEN_READONLY;
	}
	my $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', \%attr);
	$dbh->{private_slmon_driver} = 'sqlite';
	if (!$opt{readonly}) {
		$dbh->do('PRAGMA journal_mode = WAL');
		$dbh->do('PRAGMA synchronous = NORMAL');
		$dbh->do('PRAGMA busy_timeout = 5000');
		chmod 0600, $path if -e $path;
	}
	return $dbh;
}

1;
