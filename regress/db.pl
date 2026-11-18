#!/usr/bin/perl

use strict;
use warnings;
use File::Path qw(remove_tree);
use FindBin;

use lib "$FindBin::Bin/../lib";
use SLMON::Config;
use SLMON::DB;

require "$FindBin::Bin/pgutil.pl";

my $which = shift @ARGV or die "usage: db.pl sqlite|pg\n";
die "usage: db.pl sqlite|pg\n" if $which ne 'sqlite' && $which ne 'pg';

my $dir = "/tmp/slmon-db-$which-$$";
mkdir $dir, 0700 or die "mkdir $dir: $!";
my $stop;

END {
	if ($stop) {
		my $fn = $stop;
		$stop = undef;
		$fn->();
	}
	remove_tree($dir) if $dir && -d $dir;
}

my $cfg = SLMON::Config::parse($which eq 'pg' ? "db = pg\npg_db = slmon\npg_user = slmon\n" : '');
if ($which eq 'pg') {
	$stop = pg_up($dir);
	$cfg->{pg_host} = "$dir/pg";
	SLMON::Config::apply_paths($cfg, db_path => "$dir/unused.db", root => '/none');
} else {
	SLMON::Config::apply_paths($cfg, db_path => "$dir/t.db", root => '/none');
}

my $dbh = SLMON::DB::open_db($cfg);
SLMON::DB::init_schema($dbh);
if ($which eq 'sqlite') {
	my ($store) = $dbh->selectrow_array('PRAGMA temp_store');
	die "sqlite temp_store is $store\n" if !defined $store || $store != 2;
}
die "sqlite test loaded DBD::Pg\n" if $which eq 'sqlite' && $INC{'DBD/Pg.pm'};
die "pg test did not use DBD::Pg\n" if $which eq 'pg' && !$INC{'DBD/Pg.pm'};
die "driver mismatch\n" if $dbh->{private_slmon_driver} ne $which;

SLMON::DB::upsert_dish_info($dbh, {
	device_id => 'ut1', hardware_version => 'hw1', software_version => 'sw1',
	country_code => 'US', bootcount => 2, alerts_bitfield => 4, last_seen_ts => 10,
});
SLMON::DB::upsert_dish_info($dbh, {
	device_id => 'ut2', hardware_version => 'hw2', software_version => 'sw2',
	country_code => 'US', bootcount => 3, alerts_bitfield => 8, last_seen_ts => 20,
});
my ($id) = $dbh->selectrow_array('SELECT device_id FROM dish_info WHERE id = 1');
die "dish_info upsert failed\n" if !defined $id || $id ne 'ut2';
my ($info_n) = $dbh->selectrow_array('SELECT COUNT(*) FROM dish_info');
die "dish_info is not a singleton\n" if $info_n != 1;

SLMON::DB::ingest_history($dbh, {
	bootcount => 3,
	samples => [
		map { { counter => $_, ts => 1000 + $_, drop => 0, latency => 12,
		        down_bps => 80, up_bps => 8 } } (1 .. 5)
	],
});
SLMON::DB::ingest_history($dbh, {
	bootcount => 3,
	samples => [{ counter => 5, ts => 1005, drop => 0, latency => 99,
	              down_bps => 1, up_bps => 1 }],
});
my ($n) = $dbh->selectrow_array('SELECT COUNT(*) FROM history_samples');
die "conflict did not ignore the duplicate\n" if $n != 5;
my ($lat) = $dbh->selectrow_array(
    'SELECT ping_latency_ms FROM history_samples WHERE dish_counter = 5');
die "conflict updated a row\n" if $lat != 12;

my $latest = SLMON::DB::query_rows($dbh, { op => 'latest', table => 'history_samples' });
die "latest missing\n" if @$latest != 1 || $latest->[0]{dish_counter} != 5;
my $range = SLMON::DB::query_rows($dbh, {
	op => 'raw', table => 'history_samples', from => 1002, to => 1004,
});
die "range returned " . scalar(@$range) . " rows\n" if @$range != 3;
die "range order\n" if $range->[0]{dish_counter} != 2 || $range->[2]{dish_counter} != 4;

print "ok db $which\n";
exit 0;
