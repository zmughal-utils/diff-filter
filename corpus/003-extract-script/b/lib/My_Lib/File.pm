package My_Lib::File;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT    = qw(get_file);

use IO::File;

sub get_file {
	my $the_file = IO::File->new("file", "r");
	return $the_file;
}

1;
