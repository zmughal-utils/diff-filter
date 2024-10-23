package My_Lib::Time;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT    = qw(get_year);

use Time::Piece;

sub get_year {
	my $time = localtime;
	return $time->year;
}

1;
