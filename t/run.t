#!/usr/bin/env perl

use Test2::V0;

use File::Find::Rule;
use IPC::Run qw(run);
use Path::Tiny qw(path);

my $corpus_path = path('corpus');

my @test_dirs = map path($_),
	File::Find::Rule
		->mindepth(1)
		->maxdepth(1)
		->directory
		->in( $corpus_path );

for my $dir (@test_dirs) {
	subtest "Testing: $dir" => sub {
		run(
			[ qw(diff),
				qw(-r -u --unidirectional-new-file),
				$dir->child('a'),
				$dir->child('b'),

			],
			#'|',
			#[ 'bin/diff-filter-moved.pl' ],
		);
		pass;
	};
}

done_testing;
