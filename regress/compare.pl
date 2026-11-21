#!/usr/bin/perl

# Renders the pages of a list with two trees of the site, a base and a head
# (e.g. master and a pull request), and reports what the head changes:
#
#   - the data files it changes (lib/DataCheck.pm): what it changes in each,
#     by section, and the changes that are surely mistakes (text that is not
#     UTF-8, Windows line ends, a reference to a section that does not
#     exist...);
#   - the pages that fail in the head, with their errors;
#   - for each changed file, what its change alone does to the pages that
#     differ (the page rendered with that file as in the base);
#   - the pages that differ, by script and by what changed.
#
# To the list it adds pages that show the changed data files
# (lib/PagesFor.pm), so that a changed text is rendered even when no page of
# the list shows it. Pages are compared in memory: nothing is written but
# the hard-linked copies of the head in which one file is as in the base.
#
#   perl regress/compare.pl BASE HEAD [PAGES] [--jobs N] [--markdown] [--exec]
#   perl regress/compare.pl BASE HEAD [PAGES] --shard K/N --json FILE
#   perl regress/compare.pl --merge FILE... [--shards N] [--markdown]
#                           [--summary FILE] [--annotate]
#
# BASE, HEAD: the roots of two checkouts (git worktree add ../base master).
# PAGES: the list of pages (default: regress/pages.txt beside this script).
# The report goes to standard output, in Markdown with --markdown. A page
# fails when its script exits with an error, prints no page, or runs longer
# than a minute; the report shows the last lines of its errors. The exit
# code is 1 when a page fails in HEAD that rendered in BASE, or a data file
# has an error; a page that only changes is no failure.
#
# To share the work among machines, --shard K/N renders the Kth of N shares
# of the pages, and --json writes what it found to FILE instead of a report
# (shard 0 also checks the data files); --merge then reports on the files of
# the shards, and with --shards N names the shards whose file is missing
# (and exits 1). --summary FILE adds the report in Markdown to FILE (GitHub's
# $GITHUB_STEP_SUMMARY), the standard output having it as text; --annotate
# prints GitHub's annotations, which a pull request shows with its checks
# and, for a file and line, in its diff.
#
# The clock is frozen (regress/lib/FixedTime.pm) and Perl's hash order fixed,
# so that the same tree gives the same page.
#
# A page is rendered in a fork of a process that has loaded the site's code
# (regress/serve.pl), which takes about half the time of a new process; with
# --exec, in a new process, as the site renders it. The two give the same
# pages.

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use Encode ();
use FindBin qw($Bin);
use IO::Select;
use JSON::PP;
use lib "$Bin/lib";
use ReadBoth;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $SECONDS = 60;         # a page still running is stopped, and fails
my $MAX_ADDED = 200;      # pages added for the changed data files
my $MAX_UNITS = 30;       # changed files (else folders) undone one at a time
my $MAX_WEIGHT = 1000;    # pages a shard renders for that (an Ordo weighs 7)
my $MAX_KINDS = 50;       # kinds of change shown for a script

$SIG{PIPE} = 'IGNORE';    # a process that stops is seen when its answer is read

my ($jobs, $markdown, $shard, $json_out, $merge, $exec, $shards, $summary, $annotate, @args) =
  (4, 0, '0/1', undef, 0, 0, 0, undef, 0);

while (@ARGV) {
  my $a = shift @ARGV;

  if ($a eq '--jobs') {
    $jobs = shift @ARGV;
  } elsif ($a eq '--markdown') {
    $markdown = 1;
  } elsif ($a eq '--shard') {
    $shard = shift @ARGV;
  } elsif ($a eq '--json') {
    $json_out = shift @ARGV;
  } elsif ($a eq '--merge') {
    $merge = 1;
  } elsif ($a eq '--shards') {
    $shards = shift @ARGV;
  } elsif ($a eq '--summary') {
    $summary = shift @ARGV;
  } elsif ($a eq '--annotate') {
    $annotate = 1;
  } elsif ($a eq '--exec') {
    $exec = 1;
  } else {
    push @args, $a;
  }
}

if ($merge) {
  my (%run, %found);

  for my $file (@args) {
    open(my $fh, '<:raw', $file) or die "$file: $!";
    my $d = JSON::PP->new->utf8->decode(do { local $/; <$fh> });
    $run{pages} //= $d->{pages};
    die "$file: another list of pages\n" unless join("\n", @{$run{pages}}) eq join("\n", @{$d->{pages}});
    $run{$_} //= $d->{$_} for qw(listed added no_page units data);
    push @{$run{$_}}, @{$d->{$_} // []} for qw(results attribution);
    $run{tried}{$_} += $d->{tried}{$_} for keys %{$d->{tried} // {}};
    $found{$1} = 1 if ($d->{shard} // '') =~ m{^(\d+)/};
  }
  die "usage: $0 --merge FILE... [--shards N] [--markdown] [--summary FILE] [--annotate]\n" unless $run{pages};
  exit(output(\%run, [grep { !$found{$_} } 0 .. $shards - 1]));
}
my ($base, $head, $list) = @args;
die "usage: $0 BASE HEAD [PAGES] [--jobs N] [--markdown] [--shard K/N --json FILE]\n" unless $base && $head;
$base = abs_path($base);
$head = abs_path($head);
$list ||= "$Bin/pages.txt";

my ($k_shard, $n_shard) = $shard =~ m{^(\d+)/(\d+)$} or die "--shard K/N\n";

require Changed;
require PagesFor;
my @pages = read_pages($list);
my $listed = @pages;
my @changed = Changed::changed_files($base, $head);

# The pages that show the changed data files, those the list lacks: a page
# for each file in turn, to $MAX_ADDED.
my (%added, @no_page);
{
  my %have = map { $_ => 1 } @pages;
  my (%by_file, %shown, @files);

  for my $p (PagesFor::pages_for($base, $head, \@changed)) {
    my ($page, $file) = @$p;
    $shown{$file} = 1;
    next if $have{$page}++;
    push @files, $file unless $by_file{$file};
    push @{$by_file{$file}}, $page;
  }
  my @queue;

  for (my $round = 0; @queue < $MAX_ADDED; $round++) {
    my @more = map { [$by_file{$_}[$round], $_] } grep { $by_file{$_}[$round] } @files;
    last unless @more;
    push @queue, @more;
  }
  splice(@queue, $MAX_ADDED) if @queue > $MAX_ADDED;

  for (@queue) {
    push @pages, $_->[0];
    $added{$#pages} = $_->[1];
  }
  @no_page = grep { m{^web/www/.*\.txt$} && !$shown{$_} } @changed;
}

# The pages heaviest first (an Ordo of the year costs as much as seven pages
# of one hour), each shard taking the next page while it has the least work,
# so that the shards and the workers finish together.
sub weight {
  local $_ = shift;
  return /kmonth=14/ ? 7 : /command=prayOmnes/ ? 4 : /kalendar\.pl/ ? 3 : /Cofficium|Cmissa/ ? 2 : 1;
}
my @order = sort { weight($pages[$b]) <=> weight($pages[$a]) || $a <=> $b } 0 .. $#pages;
my @load = (0) x $n_shard;
my @todo;

for my $i (@order) {
  my ($s) = sort { $load[$a] <=> $load[$b] || $a <=> $b } 0 .. $n_shard - 1;
  $load[$s] += weight($pages[$i]);
  push @todo, $i if $s == $k_shard;
}

$ENV{TZ} = 'UTC';
$ENV{PERL_HASH_SEED} = 0;
$ENV{PERL_PERTURB_KEYS} = 0;
delete @ENV{qw(REQUEST_METHOD QUERY_STRING HTTP_COOKIE CONTENT_LENGTH)};

# The workers. Each takes a task and answers with one line. A task is the
# number of a page: it renders it with both trees and answers what differs
# or fails, or "=" when nothing does. Or "A UNIT PAGE TREE": it renders the
# page with TREE, the head with one changed file as in the base, and says
# what the head changes from it.
my $select = IO::Select->new;
my (%to, %pid);

for my $k (0 .. $jobs - 1) {
  pipe(my $r, my $w) or die "pipe: $!";
  pipe(my $in, my $out) or die "pipe: $!";
  my $pid = fork // die "fork: $!";

  if (!$pid) {
    close $r;
    close $out;
    binmode($w, ':encoding(UTF-8)');
    $w->autoflush(1);
    my $json = JSON::PP->new->canonical;
    my $unit_tree = '';

    while (my $task = <$in>) {
      chomp $task;

      if ($task =~ /^A\t(\d+)\t(\d+)\t(.+)$/) {
        my ($u, $i, $tree) = ($1, $2, $3);
        stop_servers($unit_tree) if $unit_tree && $unit_tree ne $tree;
        $unit_tree = $tree;
        my ($without, $ok, $err) = render($tree, $pages[$i]);
        my ($new, $new_ok) = render($head, $pages[$i]);
        my %r = (
          unit => $u,
          page => $i,
          ok => $ok,
          new_ok => $new_ok,
        );

        if ($without eq $new && $ok == $new_ok) {
          $r{same} = 1;
        } elsif ($ok && $new_ok) {
          $r{changes} = changes($without, $new);
        }
        $r{err} = $err unless $ok;
        print $w $json->encode(\%r), "\n";
        next;
      }
      my $page = $pages[$task];
      my ($old, $old_ok, $old_err) = render($base, $page);
      my ($new, $new_ok, $new_err) = render($head, $page);

      if ($old eq $new && $new_ok) {
        print $w "=\n";
        next;
      }

      # a page that fails on one side is reported by its error, not its text
      my %r = (
        page => $task,
        old_ok => $old_ok,
        new_ok => $new_ok,
      );
      $r{changes} = $old_ok && $new_ok ? changes($old, $new) : {};
      $r{old_err} = $old_err unless $old_ok;
      $r{new_err} = $new_err unless $new_ok;
      print $w $json->encode(\%r), "\n";
    }
    exit 0;
  }
  close $w;
  close $in;
  $out->autoflush(1);
  $select->add($r);
  $to{$r} = $out;
  $pid{$pid} = 1;
}

# Gives the tasks to the workers, each its next task as it answers, and
# hands each answer to ON_ANSWER. Returns the tasks that a worker stopped on.
my %buffer;

sub run_tasks {
  my ($tasks, $on_answer) = @_;
  my ($next, $done, %held, @lost) = (0, 0);
  my $give = sub {
    my $fh = shift;
    return 0 if $next >= @$tasks;
    $held{$fh} = $tasks->[$next];
    print {$to{$fh}} $tasks->[$next++], "\n";
    return 1;
  };

  for my $fh ($select->handles) {
    $give->($fh) or last;
  }

  while ($done + @lost < @$tasks && $select->count) {
    for my $fh ($select->can_read) {
      my $n = sysread($fh, my $chunk, 1 << 16);

      if (!$n) {
        push @lost, delete $held{$fh} if defined $held{$fh};    # a worker that stopped
        $select->remove($fh);
        close $fh;
        next;
      }
      $buffer{$fh} .= $chunk;

      while ($buffer{$fh} =~ s/^(.*)\n//) {
        $done++;
        $on_answer->($1, delete $held{$fh});
        $give->($fh);
      }
    }
  }
  push @lost, @$tasks[$next .. $#$tasks] if $next < @$tasks;    # no worker left
  return @lost;
}

my (@results, %told);
my @lost = run_tasks(
  \@todo,
  sub {
    my $line = shift;
    return if $line eq '=';
    my $r = JSON::PP->new->utf8->decode($line);
    push @results, $r;

    # in the log as soon as it is found, the error once
    if ($r->{old_ok} && !$r->{new_ok}) {
      my $err = $r->{new_err};
      print STDERR "Fails in this branch: $pages[$r->{page}]\n", $told{$err}++ ? '' : $err =~ s/^/    /gmr . "\n";
    }
  },
);
die sprintf(
  "Only %d of %d pages were compared: a worker stopped on %s (its error is above).\n",
  @todo - @lost,
  scalar(@todo), join(', ', map { $pages[$_] } @lost),
) if @lost;

# Each changed file under web/ (or, when there are too many, each folder)
# undone alone: the pages of this shard that differ or fail, rendered with
# a hard-linked copy of the head in which that file is as in the base.
my (@units, @attribution, %tried);
{
  my @code = grep {m{^web/}} @changed;

  if (@code <= $MAX_UNITS) {
    @units = map { [$_, [$_]] } @code;
  } else {
    my %dir;
    push @{$dir{s{/[^/]+$}{}r}}, $_ for @code;
    @units = map { ["$_/", $dir{$_}] } sort keys %dir if keys %dir <= $MAX_UNITS;
  }
  @units = () if @units < 2;

  # the pages that fail, then enough of those that differ to show each kind
  # of change once (the lightest first), a page of each script in turn, to
  # $MAX_WEIGHT for the files together (as the shares weigh them: an Ordo of
  # the year weighs 7); not a page that ran too long, which would run as
  # long with each file undone but the one at fault
  my (%queue, %seen, @pages_to_try);

  for my $r (
    sort { weight($pages[$a->{page}]) <=> weight($pages[$b->{page}]) || $a->{page} <=> $b->{page} }
    grep { $_->{old_ok} && ($_->{new_err} // '') !~ /still running after/ } @results
  ) {
    my @kinds = keys %{$r->{changes}};
    next unless !$r->{new_ok} || grep { !$seen{$_} } @kinds;
    $seen{$_} = 1 for @kinds;
    my ($script) = split(/\?/, $pages[$r->{page}]);
    push @{$queue{$r->{new_ok} ? $script : ''}}, $r->{page};
  }

  if (@units && %queue) {

    require File::Temp;
    require File::Copy;
    require File::Path;
    require File::Basename;
    my ($budget, $weight) = ($MAX_WEIGHT / @units, 0);
    my @scripts = grep { $_ ne '' } sort keys %queue;

    for my $i (@{$queue{''} // []}) {
      last if $weight >= $budget;
      push @pages_to_try, $i;
      $weight += weight($pages[$i]);
    }

    while ($weight < $budget && grep { @{$queue{$_}} } @scripts) {
      for my $script (@scripts) {
        my $i = shift @{$queue{$script}} // next;
        push @pages_to_try, $i;
        $weight += weight($pages[$i]);
        last if $weight >= $budget;
      }
    }
    @pages_to_try = sort { $a <=> $b } @pages_to_try;
    my $tmp = File::Temp::tempdir(
      'regress-XXXXXX',
      TMPDIR => 1,
      CLEANUP => 1,
    );
    my @tasks;

    for my $u (0 .. $#units) {
      my $tree = "$tmp/$u";
      mkdir $tree or die "$tree: $!";
      system('cp', '-al', "$head/web", "$tree/web") == 0 or die "cp -al $head/web: $?\n";

      for my $file (@{$units[$u][1]}) {
        my $dst = "$tree/$file";
        unlink $dst;    # the copy's link: the head's file is untouched

        if (-e "$base/$file") {
          File::Path::make_path(File::Basename::dirname($dst));
          File::Copy::copy("$base/$file", $dst) or die "$dst: $!\n";
        }
      }
      push @tasks, map {"A\t$u\t$_\t$tree"} @pages_to_try;
      $tried{$u} = @pages_to_try;
    }
    my @stopped = run_tasks(\@tasks, sub { push @attribution, JSON::PP->new->utf8->decode(shift) });
    die "A worker stopped while undoing the files one at a time (its error is above).\n" if @stopped;
  }
}
close $_ for values %to;
waitpid($_, 0) for keys %pid;

my %run = (
  pages => \@pages,
  listed => $listed,
  added => \%added,
  no_page => \@no_page,
  results => \@results,
  units => [map { $_->[0] } @units],
  attribution => \@attribution,
  tried => \%tried,
);

if ($k_shard == 0) {
  require DataCheck;
  $run{data} = [DataCheck::check_data($base, $head, \@changed)];
}

if ($json_out) {
  open(my $fh, '>:raw', $json_out) or die "$json_out: $!";
  print $fh JSON::PP->new->utf8->canonical->encode({shard => $shard, %run});
  close $fh;
  exit 0;
}
exit(output(\%run, []));

# The list: one page per line, as the part of its URL after cgi-bin/
# ("horas/officium.pl?version=Rubrics%201960%20-%201960&date=4-25-2026").
# "# …" is a comment. "NAME = a | b | c" names a list of values, and a line
# with $NAME in it stands for one page per value; {x,y,z} likewise.
sub read_pages {
  my $file = shift;
  open(my $fh, '<:encoding(UTF-8)', $file) or die "$file: $!";
  my (%lists, @out);

  while (my $line = <$fh>) {
    $line =~ s/#.*//;
    $line =~ s/^\s+|\s+$//g;
    next unless length $line;

    if ($line =~ /^(\w+)\s*=\s*(.*)$/) {
      $lists{$1} = [map {s/^\s+|\s+$//gr} split(/\|/, $2)];
      next;
    }
    my @expanded = ($line);

    while (grep {/\$\w+|\{[^}]*\}/} @expanded) {
      @expanded = map {
        my $p = $_;

        if ($p =~ /\$(\w+)/) {
          my $name = $1;
          die "$file: no list $name\n" unless $lists{$name};
          map { my $v = $_ =~ s/ /%20/gr; $p =~ s/\$$name/$v/r } @{$lists{$name}};
        } elsif ($p =~ /\{([^}]*)\}/) {
          my $alt = $1;
          map { $p =~ s/\{\Q$alt\E\}/$_/r } split(/,/, $alt);
        } else {
          $p;
        }
      } @expanded;
    }
    push @out, @expanded;
  }
  return @out;
}

# The page as the script prints it, whether it rendered (exit 0, and more
# than the headers), and if not, why. Each tree's program folder has a
# process with the site's code loaded (regress/serve.pl), and the page is
# rendered in a fork of it; with --exec, in a new process of its own, as the
# site does.
my %server;

sub render {

  my ($tree, $page) = @_;
  my ($script, $query) = split(/\?/, $page, 2);
  my @params = map { s/\+/ /gr =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ger } split(/&/, $query // '');
  my ($dir, $file) = $script =~ m{^(.*)/(.*)$};
  my ($out, $err, $status) = ('', '');

  if ($exec) {
    pipe(my $r, my $w) or die "pipe: $!";
    pipe(my $er, my $ew) or die "pipe: $!";
    my $pid = fork // die "fork: $!";

    if (!$pid) {
      close $r;
      close $er;
      open(STDOUT, '>&', $w) or exit 127;
      open(STDERR, '>&', $ew) or exit 127;
      open(STDIN, '<', '/dev/null');
      $SIG{PIPE} = 'DEFAULT';
      chdir("$tree/web/cgi-bin/$dir") or do { print STDERR "there is no folder $tree/web/cgi-bin/$dir\n"; exit 255 };
      alarm $SECONDS;    # kept through exec
      exec($^X, "-I$Bin/lib", '-MFixedTime', "$tree/web/cgi-bin/$script", @params)
        or do { print STDERR "$script: $!\n"; exit 255 };
    }
    close $w;
    close $ew;
    ($out, $err) = read_both($r, $er);
    waitpid($pid, 0);
    $status = $?;
  } else {
    my $s = $server{"$tree/$dir"} //= serve($tree, $dir);
    print {$s->[0]} join("\t", $file, @params), "\n";
    my $line = readline($s->[1]);
    my ($length, $errlength);
    ($length, $status, $errlength) = split(' ', $line) if defined $line;

    if ( !defined $line
      || ($length && (read($s->[1], $out, $length) // 0) != $length)
      || ($errlength && (read($s->[1], $err, $errlength) // 0) != $errlength))
    {
      # started again for the next page
      delete $server{"$tree/$dir"};
      close $_ for @$s[0, 1];
      waitpid($s->[2], 0);
      ($out, $err, $status) = (
        '', "regress/serve.pl, which renders the pages of $dir, stopped (status $?); the log may say why\n",
        255 << 8,
      );
    }
  }
  my $ok = $status == 0 && $out =~ /\r?\n\r?\n.{200}/s;
  $out =~ s/\Q$tree\E/TREE/g;    # a few pages print the path of their files
  return ($out, $ok ? 1 : 0, $ok ? '' : why($tree, $status, $err));
}

# a server for a tree's program folder: [requests, answers, process]
sub serve {
  my ($tree, $dir) = @_;
  pipe(my $req_r, my $req_w) or die "pipe: $!";
  pipe(my $ans_r, my $ans_w) or die "pipe: $!";
  my $pid = fork // die "fork: $!";

  if (!$pid) {
    close $req_w;
    close $ans_r;
    open(STDIN, '<&', $req_r) or exit 127;
    open(STDOUT, '>&', $ans_w) or exit 127;
    $SIG{PIPE} = 'DEFAULT';
    exec($^X, "$Bin/serve.pl", $tree, $dir, $SECONDS) or exit 127;
  }
  close $req_r;
  close $ans_w;
  $req_w->autoflush(1);
  binmode($ans_r);
  return [$req_w, $ans_r, $pid];
}

# Why a page failed: the last lines of its errors (without the time stamps
# CGI::Carp puts on them), and how it ended when that says more.
sub why {
  my ($tree, $status, $err) = @_;
  $err = Encode::decode('UTF-8', $err);
  $err =~ s/\Q$tree\E/TREE/g;
  $err =~ s/^(?:\[[^\]]*\] [\w.]+: )+//mg;
  my %seen;
  my @lines = grep { /\S/ && !$seen{$_}++ } split(/\r?\n/, $err);
  splice(@lines, 0, @lines - 5) if @lines > 5;
  my $signal = $status & 127;

  if ($signal == 14) {
    push @lines, "stopped: still running after $SECONDS s";
  } elsif ($signal) {
    push @lines, "killed by signal $signal";
  } elsif (!@lines) {
    push @lines, $status ? 'exit status ' . ($status >> 8) . ', without an error' : 'printed no page';
  }
  return join("\n", map { short($_) } @lines);
}

# What changed, each change as its kind and an example. The kind is what a
# change does whatever the day: for a change of the text, the words removed
# and added, and the tag they are in ("- Dominica (in FONT)"); for a change
# of the markup alone, the tags removed and added, the text left out. So the
# same change on many days and titles is one kind, apart from the other
# changes of the same pages. The example is the run of tags and text, old and
# new, from the token before it (which says where it is: a heading, a colour).
sub changes {

  require Algorithm::Diff;    # (only here: --merge needs no module outside Perl)
  my ($old, $new) = map { Encode::decode('UTF-8', $_) } @_;
  my @a = $old =~ /<[^>]*>|[^<]+/g;
  my @b = $new =~ /<[^>]*>|[^<]+/g;
  my %changes;

  for my $hunk (Algorithm::Diff::diff(\@a, \@b)) {

    my @minus = map { $a[$_->[1]] } grep { $_->[0] eq '-' } @$hunk;
    my @plus = map { $b[$_->[1]] } grep { $_->[0] eq '+' } @$hunk;
    my ($first) = @$hunk;
    my $before = $first->[1] ? ($first->[0] eq '-' ? $a[$first->[1] - 1] : $b[$first->[1] - 1]) : '';

    # and the token after it, which says what a changed tag holds (a title)
    my ($la) = reverse map { $_->[1] } grep { $_->[0] eq '-' } @$hunk;
    my ($lb) = reverse map { $_->[1] } grep { $_->[0] eq '+' } @$hunk;
    my $after_a = defined $la ? $a[$la + 1] : $b[$lb + 1];
    my $after_b = defined $lb ? $b[$lb + 1] : $a[$la + 1];
    my $example =
        '- '
      . short($before . join('', @minus) . substr($after_a // '', 0, 80)) . "\n+ "
      . short($before . join('', @plus) . substr($after_b // '', 0, 80)) . "\n";
    my ($ot, $nt) = map {
      join(' ', grep { !/^</ } @$_) =~ s/\s+/ /gr =~ s/^ | $//gr
    } \@minus, \@plus;
    my $kind = '';

    if ($ot eq $nt) {
      my ($om, $nm) = map {
        join('', map { /^</ ? $_ : '…' } @$_)
      } \@minus, \@plus;
      $kind = '- ' . short($om) . "\n+ " . short($nm) . "\n";
    } else {
      my @ow = split(/ /, $ot);
      my @nw = split(/ /, $nt);
      my ($where) = ($before =~ /^<\/?(\w+)/, '');    # the tag it is in, without its attributes

      for my $words (Algorithm::Diff::diff(\@ow, \@nw)) {
        for my $sign ('-', '+') {
          my @w = map { $_->[2] } grep { $_->[0] eq $sign } @$words;
          $kind .= "$sign " . short(join(' ', @w)) . ($where ? "   (in $where)" : '') . "\n" if @w;
        }
      }
    }
    $changes{$kind} //= $example;
  }
  return \%changes;
}

# the processes that render the pages of a tree, stopped
sub stop_servers {
  my $tree = shift;

  for my $key (grep { index($_, "$tree/") == 0 } keys %server) {
    my $s = delete $server{$key};
    close $_ for @$s[0, 1];
    waitpid($s->[2], 0);
  }
}

sub short {
  my $s = shift;
  $s =~ s/\s+/ /g;
  $s = substr($s, 0, 200) . '…' if length $s > 200;
  return $s;
}

sub plural {
  my ($n, $word) = @_;
  return "$n $word" . ($n == 1 ? '' : 's');
}

# The report, as text on the standard output (or Markdown), in Markdown to
# the summary file, and the annotations; the exit code.
sub output {
  my ($run, $missing) = @_;
  my $s = summarise($run);

  if (defined $summary) {
    open(my $fh, '>>:encoding(UTF-8)', $summary) or die "$summary: $!";
    report($s, $missing, 1, $fh);
    close $fh;
  }
  report($s, $missing, $markdown, \*STDOUT);
  annotate($s, $missing) if $annotate;
  return @{$s->{failed}} || @$missing || $s->{data_errors} ? 1 : 0;
}

# What the report says, from the results: the data files; the pages that
# fail, grouped by their error, those of the most pages first; what each
# changed file does alone; the pages that render on both sides and differ,
# by script and kind of change.
sub summarise {
  my $run = shift;
  my $pages = $run->{pages};
  my %s = (
    total => scalar(@$pages),
    listed => $run->{listed} // scalar(@$pages),
    kinds => {},
    example => {},
    differ => {},
    data => $run->{data},
    no_page => $run->{no_page} // [],
  );
  my %errors = map { $_ => {} } qw(failed fixed broken);

  for my $r (sort { $a->{page} <=> $b->{page} } @{$run->{results}}) {
    my $page = $pages->[$r->{page}];

    if (!$r->{old_ok} || !$r->{new_ok}) {
      my ($group, $err) =
          !$r->{new_ok} && $r->{old_ok} ? ('failed', $r->{new_err})
        : !$r->{new_ok} ? ('broken', $r->{new_err})
        : ('fixed', $r->{old_err});
      push @{$errors{$group}{$err // ''}}, $page;
      next;
    }
    my ($script) = split(/\?/, $page);
    $s{differ}{$script}++;

    while (my ($kind, $example) = each %{$r->{changes}}) {
      push @{$s{kinds}{$script}{$kind}}, $page;
      $s{example}{$script}{$kind} //= [$page, $example];
    }
  }

  for my $group (keys %errors) {
    my $e = $errors{$group};
    $s{$group} = [map { [$_, $e->{$_}] } sort { @{$e->{$b}} <=> @{$e->{$a}} || $a cmp $b } keys %$e];
  }

  # the pages added for the changed data files, by file
  my %added = %{$run->{added} // {}};
  push @{$s{added}{$added{$_}}}, $pages->[$_] for sort { $a <=> $b } keys %added;

  # what each changed file does alone
  my @units = @{$run->{units} // []};

  for my $a (sort { $a->{unit} <=> $b->{unit} || $a->{page} <=> $b->{page} } @{$run->{attribution} // []}) {
    next if $a->{same};
    my $u = $s{units}[$a->{unit}] //= {};
    my $page = $pages->[$a->{page}];

    if (!$a->{ok}) {
      push @{$u->{breaks}{$a->{err} // ''}}, $page if $a->{new_ok};    # it goes with other changes
      next;
    }

    if (!$a->{new_ok}) {
      push @{$u->{fixes}}, $page;                                      # the page fails because of it
      next;
    }
    next unless %{$a->{changes} // {}};
    $u->{pages}{$page} = 1;

    while (my ($kind, $example) = each %{$a->{changes}}) {
      push @{$u->{kinds}{$kind}}, $page;
      $u->{example}{$kind} //= [$page, $example];
    }
  }
  $s{unit_names} = \@units;
  $s{tried} = $run->{tried} // {};

  for my $d (@{$s{data} // []}) {
    $s{data_errors} += @{$d->{errors}};
    $s{data_warnings} += @{$d->{warnings}};
  }
  return \%s;
}

sub report {
  my ($s, $missing, $md, $fh) = @_;
  my $selected = select($fh);
  my $count = sub { my $n = 0; $n += @{$_->[1]} for @{$_[0]}; $n };
  my $differ = 0;
  $differ += $_ for values %{$s->{differ}};
  my $kinds = 0;
  $kinds += keys %{$s->{kinds}{$_}} for keys %{$s->{kinds}};
  my $failed = $count->($s->{failed});
  my @data = @{$s->{data} // []};
  my $added = 0;
  $added += @$_ for values %{$s->{added} // {}};
  my $code = sub { my $t = shift; $md ? "`$t`" : $t };
  my $link = sub {
    my $page = shift;
    $md ? "[$page](https://www.divinumofficium.com/cgi-bin/$page)" : $page;
  };

  my @summary;
  push @summary,
    sprintf(
      '%s %s of %d did not finish, and %s pages are not compared: the log of its "pages" job says why.',
      @$missing == 1 ? 'Shard' : 'Shards',
      join(', ', @$missing),
      $shards, @$missing == 1 ? 'its' : 'their',
    ) if @$missing;
  push @summary,
    sprintf(
      '%s changed, with %s and %s.',
      plural(scalar @data, 'data file'),
      plural($s->{data_errors} // 0, 'error'),
      plural($s->{data_warnings} // 0, 'warning'),
    ) if @data;
  push @summary,
    plural($failed, 'page') . ($failed == 1 ? ' fails' : ' fail') . ' in this branch that rendered in the base.'
    if $failed;
  push @summary,
    sprintf('%d of %d pages differ, in %s.', $differ, $s->{total}, plural($kinds, 'kind') . ' of change')
    . ($added ? sprintf(' (%d of the pages are added for the changed data files.)', $added) : '');
  print $md
    ? "## Pages compared with the base\n\n" . join("\n", map {"$_  "} @summary) . "\n\n"
    : join("\n", @summary) . "\n";

  if (keys %{$s->{differ}} > 1) {
    my @scripts = sort { $s->{differ}{$b} <=> $s->{differ}{$a} || $a cmp $b } keys %{$s->{differ}};
    print $md
      ? "| Script | Pages that differ | Kinds of change |\n|---|--:|--:|\n"
      . join('', map { sprintf("| `%s` | %d | %d |\n", $_, $s->{differ}{$_}, scalar keys %{$s->{kinds}{$_}}) } @scripts)
      . "\n"
      : join('',
        map { sprintf("  %-28s %5d pages, %5d kinds\n", $_, $s->{differ}{$_}, scalar keys %{$s->{kinds}{$_}}) }
        @scripts,);
  }

  my $size = 0;
  my $emit = sub {
    my $text = shift;
    $size += length $text;

    if ($md && $size > 800_000) {
      print "\n… the report is cut here.\n";
      return 0;
    }
    print $text;
    return 1;
  };
  my $heading = sub { $emit->($md ? "### $_[0]\n\n" : "\n=== $_[0]\n") };
  my $list = sub {
    my ($pages, $show) = @_;
    return
      join('', map {"  $_\n"} @$pages[0 .. ($#$pages < $show - 1 ? $#$pages : $show - 1)])
      . (@$pages > $show ? '  … ' . (@$pages - $show) . " more\n" : '')
      unless $md;
    my @first = @$pages[0 .. ($#$pages < 4 ? $#$pages : 4)];
    my @rest = @$pages[@first .. ($#$pages < $show - 1 ? $#$pages : $show - 1)];
    return join('', map {"- `$_`\n"} @first)
      . (
        @rest
        ? "\n<details><summary>"
        . @rest
        . " more</summary>\n\n"
        . join('', map {"- `$_`\n"} @rest)
        . (@$pages > $show ? '- … ' . (@$pages - $show) . " more\n" : '')
        . "\n</details>\n"
        : ''
      );
  };
  my $kind_text = sub {
    my ($n, $pages, $kind, $page, $example) = @_;
    return sprintf "\n== %d. on %d page(s)\n%s  e.g. %s\n%s", $n, scalar(@$pages), $kind, $page,
      $example =~ s/^/    /gmr
      unless $md;
    return sprintf(
      "**%d.** On %s:\n\n```diff\n%s```\n\nOn %s:\n\n```diff\n%s```\n",
      $n, plural(scalar @$pages, 'page'),
      $kind, $link->($page), $example,
      )
      . (
        @$pages > 1
        ? "<details><summary>All</summary>\n\n"
        . join('', map {"- `$_`\n"} @$pages[0 .. ($#$pages < 49 ? $#$pages : 49)])
        . (@$pages > 50 ? '- … ' . (@$pages - 50) . " more\n" : '')
        . "\n</details>\n"
        : ''
      ) . "\n";
  };

  # the data files: their errors and warnings, then what changed in each
  if (@data) {
    $heading->('Data files: ' . plural(scalar @data, 'file')) or return select($selected);

    for my $d (
      sort {
        @{$b->{errors}} <=> @{$a->{errors}} || @{$b->{warnings}} <=> @{$a->{warnings}} || $a->{file} cmp $b->{file}
      } @data
    ) {
      my @notes = ((map { ['error', @$_] } @{$d->{errors}}), (map { ['warning', @$_] } @{$d->{warnings}}));
      my $text = ($md ? "- `$d->{file}`" : "  $d->{file}") . " ($d->{status})\n";
      $text .=
          ($md ? '  - ' : '      ')
        . ($_->[0] eq 'error' ? ($md ? '**Error:** ' : 'ERROR: ') : 'Warning: ')
        . ($_->[1] ? "line $_->[1] " : '')
        . "$_->[2]\n"
        for @notes;
      my @sections = @{$d->{sections}};
      $text .= ($md ? '  - ' : '      ') . ($md ? "`$_`" : $_) . "\n"
        for @sections[0 .. ($#sections < 9 ? $#sections : 9)];
      $text .= ($md ? '  - ' : '      ') . '… ' . (@sections - 10) . " more sections\n" if @sections > 10;
      $emit->($text) or return select($selected);
    }
    $emit->("\n") or return select($selected);
  }

  # the failures, by error
  for (
    [failed => 'Failing in this branch, rendered in the base'],
    [fixed => 'Rendering in this branch, failed in the base (its error)'],
    [broken => 'Failing in both'],
  ) {
    my ($group, $title) = @$_;
    my @errors = @{$s->{$group}};
    next unless @errors;
    $heading->(sprintf('%s: %s, %s', $title, plural($count->(\@errors), 'page'), plural(scalar @errors, 'error')))
      or return select($selected);
    my $n = 0;

    for my $e (@errors) {
      my ($err, $pages) = @$e;
      $n++;
      my $text =
        $md
        ? sprintf(
          "**%d.** On %s:\n\n```\n%s\n```\n\n%s\n",
          $n, plural(scalar @$pages, 'page'),
          $err, $list->($pages, 50),
        )
        : sprintf(
          "\n== %d. on %s\n%s\n%s",
          $n,
          plural(scalar @$pages, 'page'),
          $err =~ s/^/    /gmr,
          $list->($pages, 10),
        );
      $emit->($text) or return select($selected);
    }
  }

  # what each changed file does alone
  my @units = @{$s->{unit_names} // []};

  if (@units) {
    my $tried = (sort { $b <=> $a } values %{$s->{tried}})[0] // 0;
    $heading->('What each change does alone') or return select($selected);
    $emit->(
      sprintf(
        "Each changed file (or folder) put back as in the base, alone, on %s that differ or fail%s.%s\n\n",
        plural($tried, 'page'),
        $tried ? ' (those that fail, then enough of the others to show each kind of change once, the lightest first)'
        : ' (none)',
        (grep { $_->[0] =~ /still running after/ } @{$s->{failed}})
        ? ' A page that ran too long is not tried: it would run as long with each file undone but the one at fault.'
        : '',
      )
    ) or return select($selected);

    for my $u (
      sort {
        scalar(keys %{($s->{units}[$b] // {})->{pages} // {}}) <=>
          scalar(keys %{($s->{units}[$a] // {})->{pages} // {}})
          || $a <=> $b
      } 0 .. $#units
    ) {
      my $x = $s->{units}[$u] // {};
      my @k = sort { @{$x->{kinds}{$b}} <=> @{$x->{kinds}{$a}} || $a cmp $b } keys %{$x->{kinds} // {}};
      my @parts;
      push @parts,
        sprintf(
          '%d of the %s tried, in %s',
          scalar keys %{$x->{pages} // {}},
          plural($tried, 'page'),
          plural(scalar @k, 'kind') . ' of change',
        ) if @k;
      push @parts, 'the cause of ' . plural(scalar @{$x->{fixes}}, 'failing page') . ' (they render without it)'
        if $x->{fixes};
      my $breaks = 0;
      $breaks += @$_ for values %{$x->{breaks} // {}};
      push @parts, plural($breaks, 'page') . ' fail without it: it goes with other changes' if $breaks;
      push @parts, 'no effect on these pages' unless @parts;
      $emit->(($md ? "**`$units[$u]`**: " : "\n== $units[$u]: ") . join('; ', @parts) . ($md ? "\n\n" : "\n"))
        or return select($selected);
      my $n = 0;

      for my $kind (@k[0 .. ($#k < 4 ? $#k : 4)]) {
        $emit->($kind_text->(++$n, $x->{kinds}{$kind}, $kind, @{$x->{example}{$kind}})) or return select($selected);
      }
      $emit->(($md ? '' : '  ') . '… and ' . plural(@k - 5, 'more kind') . "\n\n")
        or return select($selected)
        if @k > 5;
    }
  }

  # the pages added for the changed data files
  if (%{$s->{added} // {}} || @{$s->{no_page}}) {
    $heading->('Pages added for the changed data files') or return select($selected);
    my $text = '';

    for my $file (sort keys %{$s->{added}}) {
      $text .= ($md ? "- `$file`: " : "  $file: ") . join(', ', map { $code->($_) } @{$s->{added}{$file}}) . "\n";
    }
    $text .=
        ($md ? "\n" : '')
      . 'No page shows '
      . plural(scalar @{$s->{no_page}}, 'changed data file')
      . ' (the check of the data files covers them): '
      . join(', ', map { $code->($_) } @{$s->{no_page}}[0 .. ($#{$s->{no_page}} < 19 ? $#{$s->{no_page}} : 19)])
      . (@{$s->{no_page}} > 20 ? ', …' : '') . "\n"
      if @{$s->{no_page}};
    $emit->("$text\n") or return select($selected);
  }

  # by script, so that a change to one kind of page (the Ordo) does not hide
  # the others; the kinds of the most pages first
  for my $script (sort keys %{$s->{kinds}}) {
    my $k = $s->{kinds}{$script};
    my @kinds = sort { @{$k->{$b}} <=> @{$k->{$a}} || $a cmp $b } keys %$k;
    $heading->(
      sprintf('%s: %s, in %s',
        $script,
        plural($s->{differ}{$script}, 'page'),
        plural(scalar @kinds, 'kind') . ' of change',
      )
    ) or return select($selected);
    my $n = 0;

    for my $kind (@kinds[0 .. ($#kinds < $MAX_KINDS - 1 ? $#kinds : $MAX_KINDS - 1)]) {
      $emit->($kind_text->(++$n, $k->{$kind}, $kind, @{$s->{example}{$script}{$kind}})) or return select($selected);
    }

    if (@kinds > $MAX_KINDS) {
      my %rest = map { $_ => 1 } map { @{$k->{$_}} } @kinds[$MAX_KINDS .. $#kinds];
      $emit->(
        sprintf(
          "%s… and %s more kinds of change, on %s.\n\n",
          $md ? '' : "\n",
          @kinds - $MAX_KINDS,
          plural(scalar keys %rest, 'page'),
        )
      ) or return select($selected);
    }
  }
  select($selected);
}

# GitHub's annotations, ten of each kind at most: errors for the shards that
# did not finish, the data files' errors (at their line) and the pages that
# fail (at the line of the site's code the error names); warnings for the
# data files' warnings; notices for what each changed file does alone (on
# that file) and for the pages that differ.
sub annotate {

  my ($s, $missing) = @_;
  my $value = sub { $_[0] =~ s/%/%25/gr =~ s/\r/%0D/gr =~ s/\n/%0A/gr };
  my $property = sub { $value->($_[0]) =~ s/:/%3A/gr =~ s/,/%2C/gr };
  my (@error, @warning, @notice);
  my $at = sub {
    my ($file, $line) = @_;
    return ($file ? 'file=' . $property->($file) . ',' : '') . ($line ? "line=$line," : '');
  };

  push @error,
      $at->()
    . 'title='
    . $property->('Pages not compared') . '::'
    . $value->(
      sprintf(
        'Shard%s %s of %d did not finish: the log of its "pages" job says why.',
        @$missing == 1 ? '' : 's',
        join(', ', @$missing), $shards,
      )
    ) if @$missing;

  for my $d (@{$s->{data} // []}) {
    push @error,
      $at->($d->{file}, $_->[0]) . 'title=' . $property->('Data file') . '::' . $value->("$d->{file}: $_->[1]")
      for @{$d->{errors}};
    push @warning,
      $at->($d->{file}, $_->[0]) . 'title=' . $property->('Data file') . '::' . $value->("$d->{file}: $_->[1]")
      for @{$d->{warnings}};
  }

  for my $e (@{$s->{failed}}) {
    my ($err, $pages) = @$e;
    my ($file, $line) = $err =~ m{at TREE/(web/\S+?) line (\d+)};
    push @error,
        $at->($file, $line)
      . 'title='
      . $property->('Fails in this branch, on ' . plural(scalar @$pages, 'page')) . '::'
      . $value->("$err\n\ne.g. $pages->[0]");
  }
  my @units = @{$s->{unit_names} // []};

  for my $u (0 .. $#units) {
    my $x = $s->{units}[$u] or next;
    my @k = sort { @{$x->{kinds}{$b}} <=> @{$x->{kinds}{$a}} || $a cmp $b } keys %{$x->{kinds} // {}};
    next unless @k || $x->{fixes};
    my $text =
      @k
      ? sprintf(
        "Alone, this change changes %d of the %s tried, in %s. The commonest:\n%s",
        scalar keys %{$x->{pages}},
        plural((sort { $b <=> $a } values %{$s->{tried}})[0] // 0, 'page'),
        plural(scalar @k, 'kind') . ' of change', $k[0],
      )
      : 'Alone, this change makes ' . plural(scalar @{$x->{fixes}}, 'page') . ' fail.';
    push @notice,
        $at->($units[$u] =~ m{/$} ? undef : $units[$u])
      . 'title='
      . $property->('What this change does') . '::'
      . $value->($text);
  }
  my $differ = 0;
  $differ += $_ for values %{$s->{differ}};
  push @notice,
      $at->()
    . 'title='
    . $property->('Pages differ') . '::'
    . $value->(sprintf("%d of %d pages differ: the run's summary shows how.", $differ, $s->{total}))
    if $differ;
  splice(@$_, 10) for \@error, \@warning, \@notice;
  print "::error $_\n" for @error;
  print "::warning $_\n" for @warning;
  print "::notice $_\n" for @notice;
}
