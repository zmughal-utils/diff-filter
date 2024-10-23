#!/usr/bin/env perl

use strict;
use warnings;
use feature qw(say);

use IO::File;
use Time::Piece;

my $fh = IO::File->new("file", "r");
my $time = localtime;
say "The year is: " . $time->year;
