#!/usr/bin/perl
# Rewrite CHANGES at release time:
#   - rename the leading "RRDtool - master ..." block to "RRDtool X.Y.Z - DATE"
#   - prepend a fresh empty "RRDtool - master ..." placeholder
#
# Idempotent: if CHANGES already contains a "RRDtool X.Y.Z - DATE" line,
# the script exits 0 without modifications. Safe to run from every release
# job in CI; the actual mutation only happens once per release.
#
# Usage: perl conftools/finalize-changes.pl <version> <date> [file]
#   <version>  e.g. 1.9.1
#   <date>     e.g. 2026-05-13
#   [file]     defaults to CHANGES

use strict;
use warnings;

my $version = shift @ARGV;
my $date    = shift @ARGV;
my $file    = shift @ARGV // 'CHANGES';

unless (defined $version && defined $date) {
    die "usage: $0 <version> <date> [file]\n";
}
unless ($version =~ /\A[0-9]+\.[0-9]+\.[0-9]+\z/) {
    die "version must look like X.Y.Z (got: '$version')\n";
}
unless ($date =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/) {
    die "date must look like YYYY-MM-DD (got: '$date')\n";
}

open my $fh, '<', $file or die "open $file: $!\n";
local $/;
my $content = <$fh>;
close $fh;

# Normalize CRLF -> LF. On Windows CI runners actions/checkout writes
# CHANGES with CRLF line endings, which would defeat the LF-anchored
# regexes below. The file is always rewritten with LF (matching the repo).
$content =~ s/\r\n/\n/g;

# Idempotency: a "RRDtool $version - YYYY-MM-DD" header already present
# means the rewrite ran on a previous job in the same release; just exit.
if ($content =~ /^RRDtool \Q$version\E - \d{4}-\d{2}-\d{2}\b/m) {
    exit 0;
}

my $master_re = qr{
    \A
    (\s*)                        # any leading whitespace (CHANGES has a leading \n)
    RRDtool[ ]-[ ]master[ ]\.\.\.\n
    =+\n
    (.*?)                        # body of the master block
    (?=^RRDtool[ ][0-9])          # right before the next versioned block
}smx;

unless ($content =~ $master_re) {
    die "$file: no leading 'RRDtool - master ...' block found\n";
}

my $lead    = $1;
my $body    = $2;
my $hdr     = "RRDtool $version - $date";
my $under   = '=' x length($hdr);
my $rewrite =
      $lead
    . "RRDtool - master ...\n"
    . "====================\n"
    . "Bugfixes\n--------\n\n"
    . "Features\n--------\n\n"
    . "$hdr\n$under\n"
    . $body;

$content =~ s/$master_re/$rewrite/smx
    or die "$file: substitution failed unexpectedly\n";

open $fh, '>', $file or die "write $file: $!\n";
print $fh $content;
close $fh;
