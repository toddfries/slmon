#!/usr/bin/perl

# The dish child must survive its own pledge. A killed child is
# restarted by the parent, which is the pledge "rpath" loop.

use strict;
use warnings;
use FindBin;

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../blib";
use SLMON::Dish;
use SLMON::DishProc;

my $down = SLMON::DishProc::rpc_warn(
	'192.168.100.1:9200',
	"status rpc: Deadline Exceeded at /home/todd/git/sw/slmon/lib/SLMON/DishProc.pm line 117.\n",
);
die "deadline message: $down" if $down ne "slmon: dish: 192.168.100.1:9200 does not answer\n";

SLMON::DishProc::_try_pledge();
if (open my $fh, '<', '/etc/passwd') {
	die "dish pledge left /etc/passwd readable\n";
}
eval { SLMON::Dish::call('127.0.0.1:1', 'status') };
die "dish call was killed or returned success\n" if !$@;
die "unexpected dish error: $@"
    if $@ !~ /Connection refused|failed to connect|rpc/i;
print "ok dish pledge\n";
exit 0;
