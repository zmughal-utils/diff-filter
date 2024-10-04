package Text::Diff::Structured;
# ABSTRACT:

use strict;
use warnings;
use feature qw(state);
use stable v0.032 qw(postderef);
use experimental qw(signatures);

use Exporter 'import';
use Feature::Compat::Try;

our @EXPORT_OK = qw(iter_input);

use Iterator::Simple qw(iterator iter ienumerate imap list);
use Iterator::Simple::Util qw(ibefore igroup);
use List::Util qw(reduce any min max head);
use List::UtilsBy qw(partition_by min_by nsort_by);
use List::SomeUtils qw(before);
use String::Tagged::Terminal;
use Term::ANSIColor qw(colorstrip);
use Set::Tiny qw(set);
use Text::Tabs qw(expand);
use Text::ANSI::Tabs qw(ansi_expand);
use String::Util qw(trim);
use Text::Levenshtein::BV;
use String::Tokenizer;

sub iter_input($input) {
	return reduce { $b->($a) } (
		$input,
		\&iter,
		sub { imap { chomp; $_ } shift },
		# TODO does this expand handle ANSI correctly
		# (Text::Tabs::expand())?
		sub { imap { ansi_expand($_) } shift },
		\&_iter_string_tagged_terminal,
		\&ienumerate,
		sub {
			imap { +{
				line_number => $_->[0] + 1,
				text        => $_->[1],
			} } shift
		},
		\&_iter_classify,
		\&_iter_top_structure,
		\&_iter_process_ref_diff,
		\&_iter_process_moved_diff,
	);
}

sub _iter_string_tagged_terminal($iter) {
	imap {
		do {
			try {
				( $_ =~ /\e/
				? String::Tagged::Terminal->parse_terminal($_)
				: String::Tagged->new($_)
				)
			} catch($e) {
				if( $e =~ /Found an escape sequence that is not SGR/ ) {
					String::Tagged->new(colorstrip($_));
				} else {
					die $e;
				}
			}
		}
	} $iter;
}

# TODO
# - Various kinds of word-diffs
# - Using hunk information to find the end of the diff (necessary because the
#   non-porcelain word-diffs do not use a prefix so an $RE_diff_end will not
#   work).
# - Check for the no-newline at end of file comment
sub _iter_classify($iter_enumerate_hash) {
	state $RE_diff_git_header = qr{^diff --git (a/.+?) (b/.+?)$};
	state $RE_diff_any_from_to_header = qr<^[-+]{3}\ >;
	state $RE_diff_from_header = qr{^\Q---\E (.+?)(\t[^\t]*)?$};
	state $RE_diff_to_header = qr{^\Q+++\E (.+?)(\t[^\t]*)?$};
	state $RE_diff_git_binary_content = qr{^Binary files (\S*) and (\S*)};
	state $RE_diff_end = qr{^$};
	state $RE_diff_hunk_lines = qr{^@@};
	my $diff_start = 0;
	my $in_header = 0;
	imap {
		my $clean_line = $_->{text}->str;
		if ($clean_line =~ $RE_diff_git_header ) {
			# Start of headers for git's output
			$diff_start = 1;
			$in_header  = 1;
			$_->{info} = {
				type => 'diff',
				diff => {
					type    => 'file-header',
					subtype => 'git',
					from_file => $1,
					to_file   => $2,
				}
			};
		} elsif( $in_header
			||
			# this can start the header
			$clean_line =~ $RE_diff_any_from_to_header ) {
			$diff_start = 1;
			$in_header = 1;

			# Files for
			#
			#   --- ...
			#   +++ ...
			#
			# can be:
			#
			#   a/...
			#   b/...
			#   /dev/null
			if($clean_line =~ $RE_diff_from_header) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type      => 'file-header',
						subtype   => 'from',
						from_file => $1,
					}
				};
			} elsif($clean_line =~ $RE_diff_to_header) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type      => 'file-header',
						subtype   => 'to',
						to_file => $1,
					}
				};

				# last line before content
				$in_header = 0;
			} elsif($clean_line =~ $RE_diff_git_binary_content) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type      => 'body',
						subtype   => 'comment-binary',
						from_file => $1,
						to_file   => $2,
					}
				};

				# in body already
				$in_header = 0;
			} else {
				# generic header line
				$_->{info} = {
					type => 'diff',
					diff => {
						type    => 'file-header',
						subtype => 'generic',
					}
				};
			}
		} elsif(
			$diff_start
			&& !$in_header
			&& $clean_line !~ $RE_diff_end ) {
			if( $clean_line =~ $RE_diff_hunk_lines ) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type => 'body',
						subtype => 'hunk-lines',
					},
				};
			} elsif( $clean_line =~ /^\-/ ) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type => 'body',
						subtype => 'removed',
					},
				};
			} elsif( $clean_line =~ /^\+/ ) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type => 'body',
						subtype => 'added',
					},
				};
			} elsif( $clean_line =~ /^\ / ) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type => 'body',
						subtype => 'context',
					},
				};
			} elsif( $clean_line =~ /^\\/ ) {
				$_->{info} = {
					type => 'diff',
					diff => {
						type => 'body',
						subtype => 'comment',
					},
				};
			} else {
				die "unknown diff hunk prefix: $clean_line";
			}
		} else {
			$diff_start = 0;
			$_->{info} = { type => 'non-diff' };
			# no-op
		}

		$_;
	} $iter_enumerate_hash;
}

sub _iter_top_structure($iter_classified) {
	my $peek = <$iter_classified>;
	return iterator {
		return unless defined $peek;
		my @group_items = ($peek);
		while(defined($peek = <$iter_classified>)) {
			last if $peek->{info}{type} ne $group_items[0]{info}{type};
			push @group_items, $peek;
		}
		return {
			type  => $group_items[0]{info}{type},
			items => \@group_items,
		};
	};
}

sub _iter_process_ref_diff($iter_top_structure) {
	state $file_header_subtypes = set(qw(git from to));
	return imap {
		if( $_->{type} eq 'diff' ) {
			my $current_info_header;
			my $current_info;
			my $previous_type = '';
			for my $item ($_->{items}->@*) {
				my $info_diff = $item->{info}{diff};
				$current_info_header = {}, $current_info = {}
					if $info_diff->{type} eq 'file-header'
					&& $previous_type ne 'file-header';

				if(  $info_diff->{type} eq 'file-header'
				  && $file_header_subtypes->has(  $info_diff->{subtype} )
				) {
					$current_info_header->{'file-header'}{
						$info_diff->{subtype}
					} = $item;
				} elsif(
					$info_diff->{type} eq 'body'
				) {
					if( $info_diff->{subtype} eq 'hunk-lines' ) {
						$current_info = {
							%$current_info_header,
							body => { 'hunk-lines' => $item },
						};
					} else {
						$item->{info}{diff}{ref} = $current_info;
					}
				}
				$previous_type = $item->{info}{diff}{type};
			}
			return $_;
		} else {
			return $_;
		}
	} $iter_top_structure;
}

sub _ws_split { split /\s+/, shift }
# character tokenize
sub _tokenize_char { map { split // } _ws_split(@_); }
# word tokenize
sub _tokenize_word { map { split /[\w:]+\K/ } _ws_split(@_); }
# some weird word+op tokenize
sub _tokenize_word_op {
	map { split /(?=[^\w:=>-]+)/ } _ws_split(@_);
}
sub _tokenize_st {
	state $tokenizer = String::Tokenizer->new();
	$tokenizer->tokenize( trim(shift), '?:()+*-=<>' , 0 );
	#use DDP; print np $tokenizer->getTokens;#DEBUG
	$tokenizer->getTokens;
}

sub tokenize { goto &_tokenize_st; }


sub _iter_process_moved_diff($iter_ref_diff) {
	state $body_subtype_analyze = set(qw(added removed));
	state $lev = Text::Levenshtein::BV->new;
	return imap {
		if( $_->{type} eq 'diff' ) {
			my %parts =
				partition_by { $_->[0]{info}{diff}{subtype} }
				grep
					   $_->[0]{info}{diff}{type} eq 'body'
					&& $body_subtype_analyze->has($_->[0]{info}{diff}{subtype})
					,
				List::Util::zip( $_->{items}, [ 0..$_->{items}->$#* ] ) ;
			my %texts;
			for my $subtype (keys %parts) {
				$texts{$subtype}->@* = map {
					[
						$_->[0]{text}->str,
						[ tokenize($_->[0]{text}->substr(1)->str) ],
						$_,
					]
				} $parts{$subtype}->@*
			}
			my @compared;
			for my $removed_item ($texts{removed}->@*) {
				next unless $removed_item->[1]->@*;
				my @matches =
					nsort_by { $_->[1] }
					grep {
						$_->[1] <= int( ($ENV{T} // 0.3) * max(0+$removed_item->[1]->@*, 0+$_->[0]->@*))
						#&&
						#$_->[2][-1][0] == $_->[2][-1][1]
						;
					}
					map {
						my $distance = $lev->distance($removed_item->[1], $_->[1]);
						my $ses = $lev->SES( $removed_item->[1], $_->[1] );
						[
							$_,
							$distance,
							$ses,
						]
					}
					grep { $_->[1]->@* } $texts{added}->@*;
				push @compared,
					map {
						my @zero_dist = before { $_->[1] != 0 } $_->{to}->@*;
						$_->{to}->@* = @zero_dist ? @zero_dist : head(2, $_->{to}->@*);
						$_->{has_zero_dist} = !!@zero_dist;
						$_;
					}
					map { $_->{to}->@* ? $_ : () }
					+{
						from => $removed_item->[0],
						to   => [ map {
								my @m = @$_;
								[
									$m[0][0],
									@m[1..$#m]
								]
							} @matches ],
					}
			}
			#use DDP; print np(%parts, colored => 1), "\n";#DEBUG
			#use DDP; print np(%texts, colored => 1, seen_override => 1 ), "\n";#DEBUG
			use DDP; print np(@compared, colored => 1, seen_override => 1 ), "\n";#DEBUG

			return $_;
		} else {
			return $_;
		}
	} $iter_ref_diff;
}

1;
