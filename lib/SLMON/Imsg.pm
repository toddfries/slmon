package SLMON::Imsg;

use strict;
use warnings;

use POSIX ();
use SLMON ();
use XSLoader;

XSLoader::load('SLMON::Imsg');

sub open {
	my ($class, $fd) = @_;
	my $self = $class->new($fd + 0);
	$self->allow_fdpass;
	my $rc = $self->set_maxsize(SLMON::IMSG_MAX);
	die "imsgbuf_set_maxsize failed\n" if !defined $rc || $rc < 0;
	return $self;
}

sub _flush_block {
	my ($self) = @_;
	my $rc = $self->flush;
	die "imsgbuf_flush: $!\n" if !defined $rc || $rc != 0;
	return;
}

sub send {
	my ($self, $type, $payload) = @_;
	$payload = '' unless defined $payload;
	die "imsg payload exceeds max\n" if length($payload) > SLMON::IMSG_MAX;
	my $rc = $self->compose($type, $payload, -1);
	die "imsg_compose failed\n" if !defined $rc || $rc != 1;
	$self->_flush_block;
	return;
}

# imsg closes the descriptor it is given, after the message is written.
# Duplicate first so the caller's fd stays open.
sub send_fd {
	my ($self, $type, $payload, $fd) = @_;
	$payload = '' unless defined $payload;
	die "imsg payload exceeds max\n" if length($payload) > SLMON::IMSG_MAX;
	my $dup = POSIX::dup($fd + 0);
	die "dup: $!\n" if !defined $dup || $dup < 0;
	my $rc = $self->compose($type, $payload, $dup);
	if (!defined $rc || $rc != 1) {
		die "imsg_compose fd failed\n";
	}
	$self->_flush_block;
	return;
}

sub recv {
	my ($self) = @_;
	while (1) {
		my $msg = $self->get;
		return $msg if $msg;
		my $r = $self->read_more;
		return undef if defined $r && $r == 0;
		die "imsgbuf_read: $!\n" if !defined $r || $r < 0;
	}
}

1;
