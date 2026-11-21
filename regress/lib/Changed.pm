package Changed;

# The files under web/ that differ between two trees of the site: from git
# when the head is a checkout of the repository that has the base's commit
# (its uncommitted changes included), else by comparing the files (a file
# that is the same inode on both sides, as in a hard-linked copy, is the
# same).
#
#   my @files = changed_files($base, $head);    # "web/www/horas/...", sorted

use strict;
use warnings;
use Cwd ();
use File::Compare ();
use File::Find ();
use Exporter qw(import);

our @EXPORT_OK = qw(changed_files);

# a command's lines, its errors dropped; undef when it fails
sub lines {
  my $pid = open(my $fh, '-|') // return;

  if (!$pid) {
    open(STDERR, '>', '/dev/null');
    exec(@_) or exit 127;
  }
  my @lines = map { chomp; $_ } <$fh>;
  close $fh or return;
  return \@lines;
}

sub changed_files {

  my ($base, $head) = @_;
  my %files;
  my $top = lines('git', '-C', $head, 'rev-parse', '--show-toplevel');
  my $rev =
       $top
    && Cwd::abs_path($top->[0] // '') eq Cwd::abs_path($head)
    && lines('git', '-C', $base, 'rev-parse', '--verify', '-q', 'HEAD');
  my $diff = $rev && @$rev && lines('git', '-C', $head, 'diff', '--name-only', '--no-renames', $rev->[0], '--', 'web');
  my $new = $diff && lines('git', '-C', $head, 'ls-files', '--others', '--exclude-standard', '--', 'web');

  if ($diff && $new) {
    $files{$_} = 1 for @$diff, @$new;
    return sort keys %files;
  }

  for my $tree ($base, $head) {
    next unless -d "$tree/web";
    File::Find::find(
      {
        no_chdir => 1,
        wanted => sub { $files{substr($File::Find::name, length($tree) + 1)} = 1 if -f $File::Find::name },
      },
      "$tree/web",
    );
  }
  return sort grep {
    my @b = stat "$base/$_";
    my @h = stat "$head/$_";
    !@b
      || !@h ? 1 : $b[0] == $h[0]
      && $b[1] == $h[1] ? 0 : $b[7] != $h[7] ? 1 : File::Compare::compare("$base/$_", "$head/$_") != 0;
  } keys %files;
}

1;
