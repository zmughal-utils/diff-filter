#!/usr/bin/env perl
# PODNAME:
# ABSTRACT:

use strict;
use warnings;

use feature qw(say);
use stable v0.032 qw(postderef);
use experimental qw(signatures);
use FindBin qw( $RealBin );
use lib "$RealBin/../lib";
use lib::projectroot qw(lib);
use Text::Diff::Structured qw(
    iter_input
);
use List::Util qw<max>;

my $iter = iter_input(\*STDIN);

#say $_->{text} while <$iter>;
#p $_ while <$iter>;

sub print_group($group) {
	my $max_width_items = max map $_->{text}->length, $group->{items}->@*;
	my $print_prefix = 0;
	my $print_suffix = 0;
	(
		String::Tagged::Terminal->new()
		. String::Tagged->join("",
			map { String::Tagged->from_sprintf(
				"@{[ ('%-30s:')x!! $print_prefix ]}"
				."%-@{[ 1+$max_width_items ]}s"
				."@{[ (':%s')x!!$print_suffix ]}"
				."\n",
				( $print_prefix
				? join("::", grep defined,
					$group->{type},
					$_->{line_number},
					$_->{info}{diff}{type},
					$_->{info}{diff}{subtype})
				: ()
				),
				$_->{text},
				( $print_suffix
				?
					do {""}
					#do { use Data::Dumper::Concise (); Data::Dumper::Concise::Dumper($_) }
					#do { use Data::Dumper::Compact qw(ddc); ddc($_, { max_width => $max_width_items }) }
					#do { use DDP; np($_, colored=>1, multiline=>0) }
				: ()
				)
			) }
				$group->{items}->@*
		)
	)->print_to_terminal;

}

while(<$iter>) {
	if( $_->{type} eq 'non-diff' ) {
		print_group($_);
	} else {
		print_group($_);
		#use DDP; say np $_, colored => 1;
	}
	#use DDP; say np $_, colored => 1;
}

__END__


