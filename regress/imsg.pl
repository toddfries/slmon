#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use IO::Socket::INET;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../blib";
use SLMON ();
use SLMON::Imsg;

socketpair(my $parent, my $child, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $listen = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => 0,
	Proto     => 'tcp',
	Listen    => 5,
	Reuse     => 1,
) or die "listen: $!";
my $port = $listen->sockport;

my $pid = fork();
die "fork: $!" if !defined $pid;
if ($pid == 0) {
	close $parent;
	my $ib = SLMON::Imsg->open(fileno($child));
	my $hist = $ib->recv or die "missing history\n";
	die "history type\n" if $hist->{type} != SLMON::IMSG_HISTORY;
	die "history chunk is not under 16KB\n" if length($hist->{data}) >= 16384;
	die "history chunk empty\n" if length($hist->{data}) < 8;
	my $passed = $ib->recv or die "missing listen fd message\n";
	die "listen fd was not passed\n" if !defined $passed->{fd} || $passed->{fd} < 0;
	$ib->send(SLMON::IMSG_ACK, 'ready');
	open my $ls, '+<&=', $passed->{fd} or die "fdopen: $!\n";
	my $addr = accept(my $cli, $ls);
	die "accept failed\n" if !$addr;
	my $ping = '';
	sysread $cli, $ping, 4;
	die "accepted socket did not receive ping\n" if $ping ne 'ping';
	close $cli;
	my $big = $ib->recv or die "missing large message\n";
	die "20KB payload missing\n" if length($big->{data}) != 20000;
	exit 0;
}

close $child;
my $ib = SLMON::Imsg->open(fileno($parent));
my $payload = '{"samples":[' . join(',', map { '{"counter":' . $_ . '}' } (1 .. 30)) . ']}';
die "fixture is not under 16KB\n" if length($payload) >= 16384;
$ib->send(SLMON::IMSG_HISTORY, $payload);
$ib->send_fd(SLMON::IMSG_LISTENING, 'listen', fileno($listen));
my $ack = $ib->recv or die "child did not ack the listen fd\n";
die "ack type\n" if $ack->{type} != SLMON::IMSG_ACK;
my $conn = IO::Socket::INET->new(
	PeerAddr => '127.0.0.1',
	PeerPort => $port,
	Proto    => 'tcp',
	Timeout  => 5,
) or die "connect: $!";
syswrite $conn, 'ping' or die "write: $!";
close $conn;
$ib->send(SLMON::IMSG_OBSTRUCTION, 'Y' x 20000);
waitpid $pid, 0;
die "imsg child failed\n" if $?;
print "ok imsg\n";
exit 0;
