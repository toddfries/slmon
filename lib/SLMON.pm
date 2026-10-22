package SLMON;

use strict;
use warnings;

use JSON::PP ();

our $VERSION = '0.1.0';
our $PROG = 'sld';
# Foreground and slctl keep stderr. The daemon clears this after it forks.
our $LOG_STDERR = 1;

use constant {
	IMSG_NEED_INIT    => 1,
	IMSG_SET_AUTH     => 2,
	IMSG_READY        => 3,
	IMSG_CONFIG       => 4,
	IMSG_STATUS       => 5,
	IMSG_HISTORY      => 6,
	IMSG_DISH_INFO    => 7,
	IMSG_OBSTRUCTION  => 8,
	IMSG_EVENT        => 9,
	IMSG_WEATHER      => 10,
	IMSG_QUERY        => 11,
	IMSG_ROWS         => 12,
	IMSG_QUERY_DONE   => 13,
	IMSG_LISTENING    => 14,
	IMSG_ATTACH       => 15,
	IMSG_SHUTDOWN     => 16,
	IMSG_ACK          => 17,
	IMSG_LOGIN        => 18,
	IMSG_LOGIN_RESULT => 19,
	IMSG_RELOAD       => 20,
	IMSG_MAX          => 262144,
	# Fastest dish poll and page timer. The default poll stays 30s.
	MIN_POLL_S        => 2,
	MAP_POLL_S        => 300,
};

my $JSON = JSON::PP->new->utf8->canonical->allow_nonref;

sub json_encode {
	my ($data) = @_;
	return $JSON->encode($data);
}

sub json_decode {
	my ($bytes) = @_;
	return undef if !defined $bytes || $bytes eq '';
	return $JSON->decode($bytes);
}

sub proc_title {
	my ($role) = @_;
	require SLMON::Imsg;
	# $0 is reported as "perl: sld: …". set_title uses setprogname so
	# the process title is exactly "sld: $role" for pgrep -xf.
	SLMON::Imsg::set_title("sld: $role");
	return;
}

# Operator line, with the program name. A trailing newline is added.
sub err {
	my ($msg) = @_;
	$msg =~ s/\s+\z//;
	return "$PROG: $msg\n";
}

sub _syslog {
	my ($msg) = @_;
	eval {
		require Sys::Syslog;
		Sys::Syslog::setlogsock('native');
		Sys::Syslog::openlog('sld', 'ndelay,pid', 'daemon');
		Sys::Syslog::syslog('info', '%s', $msg);
	};
	return;
}

# Stderr while foreground. Syslog after the daemon has forked.
sub op {
	my ($msg) = @_;
	return if $SLMON::IN_OP;
	local $SLMON::IN_OP = 1;
	$msg =~ s/\s+\z//;
	if ($LOG_STDERR) {
		print STDERR "$PROG: $msg\n";
	} else {
		_syslog($msg);
	}
	return;
}

# The uninitialized-database refusal is shown and logged before the fork.
sub op_both {
	my (@msg) = @_;
	for my $msg (@msg) {
		$msg =~ s/\s+\z//;
		print STDERR "$PROG: $msg\n";
		_syslog($msg);
	}
	return;
}

sub bool01 {
	my ($v) = @_;
	return 0 if !defined $v || $v eq '' || $v eq '0';
	return 0 if $v eq 'false';
	return $v ? 1 : 0;
}

# Installed default. -d overrides this. The port creates the directory.
sub default_db_path {
	return '/var/sl/sl.db';
}

1;
