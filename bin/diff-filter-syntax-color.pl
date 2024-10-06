#!/usr/bin/env perl
# SPDX-License-Identifier: MIT
# PODNAME:
# ABSTRACT:

use strict;
use warnings;

use Devel::StrictMode;
use Term::ANSIColor qw(color colored colorstrip);
use Pod::Usage qw(pod2usage);
use Getopt::Long::Descriptive qw(describe_options);
use Syntax::Kamelon;
use Syntax::Kamelon::Format::ANSI;
use List::SomeUtils qw(pairwise);
use List::Util::MaybeXS qw(max first);
use File::Basename qw(basename);
use Text::Tabs qw(expand);

# Define the options
my ($opt, $usage) = describe_options(
  "%c %o [--] path-specs...",
  [],
  [ 'help|h',       "print usage message and exit", { shortcircuit => 1 } ],
);

# Remove a leading option separator ('--') from @ARGV if it exists
shift @ARGV if @ARGV && $ARGV[0] eq '--';



# ANSI color code pattern
my $ansi_pattern = qr/\e\[[0-9;]*m/;

if( $opt->help ) {
    pod2usage({
        -verbose => 99,
        -output => \*STDOUT,
        -exitval => 0 });
}

# For lines before diff starts
my $diff_start = 0;

my @chunks;
my $current_chunk;
my $in_header = 0;
while (my $line = <STDIN>) {
    # Remove ANSI color codes for matching
    my $clean_line = $line;
    $clean_line =~ s/$ansi_pattern//g;

    if ($clean_line =~ m{^diff --git a/(.+?) b/(.+?)$}) {
        push @chunks, $current_chunk = { header_lines => [], content => [] }
            unless $in_header;
        $diff_start = 1;
        $in_header = 1;
        push $current_chunk->{header_lines}->@*, $line;
        $current_chunk->{diff_files_header}->@* = ($1, $2);
    } elsif( $in_header || $clean_line =~ /^[-+]{3}\ / ) {
        push @chunks, $current_chunk = { header_lines => [], content => [] }
            unless $in_header;
        $diff_start = 1;
        $in_header = 1;
        push $current_chunk->{header_lines}->@*, $line;
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
        if($clean_line =~ /^\Q---\E (.+?)(\t[^\t]*)?$/) {
            $current_chunk->{diff_files}[0] = $1;
        } elsif($clean_line =~ /^\Q+++\E (.+?)(\t[^\t]*)?$/) {
            $current_chunk->{diff_files}[1] = $1;
            $in_header = 0;
        } elsif($clean_line =~ /^Binary files (\S*) and (\S*)/) {
            $current_chunk->{diff_files}->@* = ($1, $2);
            $in_header = 0;
        }
    } elsif($diff_start && $clean_line !~ /^$/ ) {
        if( $clean_line =~ /^@@/ ) {
            push $current_chunk->{content}->@*, {
                group => $line,
            };
        } else {
            my $final_group = $current_chunk->{content}[-1];
            push $final_group->{lines}->@*, $line;
        }
    } else {
        $diff_start = 0;
        push @chunks, $current_chunk = { lines => [] }
            unless exists $current_chunk->{lines};
        push $current_chunk->{lines}->@*, $line;
    }
}

my $background_color = 'bright_black';
my %prefix_color = (
    ' ' => 'on_'.$background_color,
    '+' => 'on_green',
    '-' => 'on_red',
);

my $kam = Syntax::Kamelon->new(
    formatter => ['Base'],
);
my %prefix_ansi_formattable = map {
    ( $_->[0] => Syntax::Kamelon::Format::ANSI->new( $kam, theme => $_->[1] )->{FORMATTABLE} )
} ( [ ' ', $background_color ], [ '+', 'green' ], ['-', 'red'] );


sub get_syntax {
    my ($filename) = @_;
    my $syntax = $kam->SuggestSyntax( $filename );

    if( ! $syntax ) {
        return 'Perl' if basename($filename) eq 'cpanfile';
        return 'Makefile' if basename($filename) eq 'Makefile';
        return 'Dockerfile' if basename($filename) =~ /^Dockerfile\.?/;
    }

    return $syntax;
}

my $tt = Template->new;

my $template = <<'EOT';
[% FOREACH line = lines ~%]
        [%# SET format_table = prefix_ansi_formattable.item(line.prefix) ~%]
        [% SET format_table = prefix_ansi_formattable.item(' ') ~%]
        [% SET tagend = format_table.item('Normal') ~%]
        [% color(line.prefix_tagend) %][% line.prefix %][% tagend ~%]
        [% SET text_length = 1 ~%]
        [% FOREACH snippet = line.line ~%]
                [% format_table.item(snippet.tag) %][% snippet.text %][% tagend ~%]
                [% SET text_length = text_length + snippet.text.length ~%]
        [% END ~%]
        [% color(background_color) %][% padding_char.repeat(max_length - text_length) ~%]
        [% newline ~%]
[% END ~%]
EOT

#local $Text::Tabs::tabstop = 2;
for my $chunk (@chunks) {
    if( exists $chunk->{lines} ) {
        print join '',
            $chunk->{lines}->@*;
        next;
    }
    print join '',
        map colored(['yellow'], $_), $chunk->{header_lines}->@*;

    next unless exists $chunk->{content} && $chunk->{content}->@*;

    my $syntax = get_syntax( first { $_ ne '/dev/null' } reverse $chunk->{diff_files}->@* );
    $kam->Syntax($syntax) if $syntax;
    my $max_length =
        max map {
            my $group = $_;
            max
                length expand($group->{group}),
                map length expand($_), $group->{lines}->@*
        } $chunk->{content}->@*;
    print join '',
        map {
            my $group = $_;

            my @out;

            chomp(my $group_txt = $group->{group});
            push @out,
                colored([ 'on_blue' ], sprintf("%-${max_length}s", expand($group_txt) ) ),
                colored(['reset'], "\n");

            my @p_lines = map {
                my $p_s = [ $_ =~ /^([-+ ])(.*)$/ ];
                $p_s->[1] = expand($p_s->[1]);
                $p_s;
            } $group->{lines}->@*;


            my @formatted_lines;

            my $template_data;
            if( $syntax ) {
                $kam->Parse(
                    join "\n", map { $_->[1] } @p_lines
                );
                my $formatter_data = $kam->Formatter->GetData;
                $kam->Reset;

                $template_data->{lines}->@* =
                    pairwise {
                            +{
                                prefix => $a->[0],
                                prefix_tagend => $prefix_color{$a->[0] },
                                line   => $b
                            }
                    } @p_lines, $formatter_data->{content}->@*;
                $template_data->{$_} = $formatter_data->{$_} for qw(newline);
            } else {
                @formatted_lines = map { expand($_->[1]) } @p_lines;
                $template_data->{lines}->@* =
                    pairwise {
                        +{
                            prefix => $a->[0],
                            prefix_tagend => $prefix_color{$a->[0] },
                            line   => [ { tag => 'Normal', text => $b } ],
                        }
                    } @p_lines, @formatted_lines;
                    $template_data->{newline} = "\n";
            }
            $template_data->{prefix_ansi_formattable} = \%prefix_ansi_formattable;
            $template_data->{color} = \&color;
            $template_data->{max_length} = $max_length;
            $template_data->{background_color} = $background_color;
            $template_data->{padding_char} = ' ';

            @formatted_lines = split /\n/, do {
                my $out;
                $tt->process(\$template, $template_data, \$out ) or die $tt->error;
                $out
            };

            push @out, map { $_ . colored(['reset'], "\n") } @formatted_lines;

            @out;
        }
        $chunk->{content}->@*;
}

__END__

