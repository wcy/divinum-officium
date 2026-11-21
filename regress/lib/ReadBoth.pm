package ReadBoth;

# What a process prints on its standard output and its standard error, read
# from their pipes together, so that neither fills while the other is read.
#
#   my ($out, $err) = read_both($out_fh, $err_fh);

use strict;
use warnings;
use IO::Select;
use Exporter qw(import);

our @EXPORT = qw(read_both);

sub read_both {
  my %text = map { $_ => '' } @_;
  my $select = IO::Select->new(@_);

  while ($select->count) {
    for my $fh ($select->can_read) {
      my $n = sysread($fh, my $chunk, 1 << 16);
      $n ? ($text{$fh} .= $chunk) : $select->remove($fh);
    }
  }
  return map { $text{$_} } @_;
}

1;
