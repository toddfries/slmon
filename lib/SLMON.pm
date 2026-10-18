package SLMON;

use strict;
use warnings;

use JSON::PP ();

our $VERSION = '0.1.0';

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
	IMSG_MAX          => 262144,
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
	$0 = "slmon: $role";
	return;
}

sub bool01 {
	my ($v) = @_;
	return 0 if !defined $v || $v eq '' || $v eq '0';
	return 0 if $v eq 'false';
	return $v ? 1 : 0;
}

# Checkout default sits next to lib/. Otherwise the per-user data dir.
sub default_db_path {
	my ($root) = @_;
	if (defined $root && -f "$root/lib/SLMON.pm") {
		return "$root/var/slmon.db";
	}
	my $home = $ENV{HOME} || '/tmp';
	return "$home/.local/share/slmon/slmon.db";
}

1;
