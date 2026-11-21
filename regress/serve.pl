#!/usr/bin/perl

# A program folder of one tree (web/cgi-bin/horas or missa) with the site's
# modules loaded once, for regress/compare.pl: each page is rendered in a
# fork of it. The page's script runs afresh in the fork, as in a new
# process; only the modules it uses are loaded beforehand, which saves about
# a third of a page's time.
#
#   perl regress/serve.pl TREE DIR SECONDS
#
# Requests come on standard input, one a line: the script and its
# parameters, separated by tabs. Each answer is a line "LENGTH STATUS
# ERRLENGTH" (STATUS: the script's exit status), then the LENGTH bytes the
# script printed, then the ERRLENGTH bytes of its errors and warnings. A page
# still running after SECONDS is stopped (STATUS: signal 14).

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

my $here;

BEGIN { $here = dirname(abs_path(__FILE__)) }

use lib "$here/lib";
use FixedTime;    # before the site's code is compiled
use ReadBoth;

my ($tree, $dir, $seconds) = @ARGV;
my $folder = abs_path("$tree/web/cgi-bin/$dir");

# without the folder, every page fails, and says why
if (!$folder || !chdir $folder) {
  my $error = "there is no folder $tree/web/cgi-bin/$dir\n";
  $| = 1;
  print length(''), ' ', 255 << 8, ' ', length($error), "\n", $error while <STDIN>;
  exit 0;
}
my @scripts = sort glob("$folder/*.pl");

# the answers go out on a copy of standard output; anything the loading
# prints is dropped
open(my $answers, '>&', \*STDOUT) or die "stdout: $!";
open(STDOUT, '>', '/dev/null') or die "/dev/null: $!";

# FindBin as the folder's scripts see it, and their library
$0 = $scripts[0];
require FindBin;
FindBin::again();
{ no warnings 'once'; unshift @INC, "$FindBin::Bin/.."; }

# The modules the scripts use: packages, which do nothing when loaded.
for my $script (@scripts) {
  open(my $fh, '<', $script) or next;

  while (<$fh>) {
    eval "require $1; 1" if /^use ((?:DivinumOfficium|CGI|POSIX|Time|File|Encode)\b[\w:]*)/;
  }
}

# The files they require by "$Bin/..." run code at their top, which a page
# must run itself, in its order. Each is compiled here as the body of a
# function, which defines its subs and runs nothing. A page's require of the
# file, where a new process would load it, defines the file's subs again
# (a file may redefine a sub of the script or of another file) and calls the
# function.
my (%compiled, $n);

BEGIN {
  *CORE::GLOBAL::require = sub {
    my ($file) = @_;

    # an error of a require says where the page's code has it, not here
    my $c = $compiled{$file} or do {
      my ($from, $line, $before) = ((caller)[1, 2], $@);
      my $ok = eval { CORE::require($file) };
      die $@ =~ s/ at \Q${\__FILE__}\E line \d+/ at $from line $line/gr if $@;
      $@ = $before;
      return $ok;
    };
    return 1 if $INC{$file};
    $INC{$file} = $file;
    no strict 'refs';
    no warnings 'redefine';
    *{$_} = $c->{subs}{$_} for keys %{$c->{subs}};
    $c->{run}->();
    return 1;
  };
}

sub compile_file {
  my ($path) = @_;
  return if $compiled{$path} || !-f $path;
  open(my $fh, '<', $path) or return;
  my $source = do { local $/; <$fh> };
  $source =~ s/^__(?:END|DATA)__\b.*//ms;
  my $name = 'Regress::Serve::file' . ++$n;
  return unless eval "no strict; no warnings; package main; sub $name {\n#line 1 \"$path\"\n$source\n;\n}\n1;";

  # the subs it defines, as it defines them
  my ($package, %subs) = ('main');

  for (split(/\n/, $source)) {
    $package = $1 if /^\s*package\s+([\w:]+)\s*;/;
    $subs{/::/ ? $1 : "${package}::$1"} = 1 if /^\s*sub\s+([\w:]+)/;
  }
  no strict 'refs';
  $compiled{$path} = {
    run => \&{$name},
    subs => {map { defined &{$_} ? ($_ => \&{$_}) : () } keys %subs},
  };
  compile_file("$FindBin::Bin/$1") while $source =~ /^\s*require "\$Bin\/([^"]+)";/mg;
}

for my $script (@scripts) {
  open(my $fh, '<', $script) or next;

  while (<$fh>) {
    compile_file("$FindBin::Bin/$1") if /^require "\$Bin\/([^"]+)";/;
  }
}

binmode(STDIN);
binmode($answers);
$answers->autoflush(1);

while (my $line = <STDIN>) {
  chomp $line;
  my ($script, @params) = split(/\t/, $line, -1);
  pipe(my $r, my $w) or die "pipe: $!";
  pipe(my $er, my $ew) or die "pipe: $!";
  my $pid = fork // die "fork: $!";

  if (!$pid) {
    close $r;
    close $er;
    close $answers;
    open(STDOUT, '>&', $w) or exit 127;
    open(STDERR, '>&', $ew) or exit 127;
    close $w;
    close $ew;
    close STDIN;    # and with it the line number an error would give of it
    open(STDIN, '<', '/dev/null');
    $0 = "$folder/$script";
    FindBin::again();
    @ARGV = @params;
    -f $0 or die "there is no script $dir/$script\n";
    alarm $seconds;
    my $ok = do $0;
    print STDERR $@ if $@;    # "do" keeps the error from being printed
    exit(defined $ok || !$@ ? 0 : 255);
  }
  close $w;
  close $ew;
  my ($out, $err) = read_both($r, $er);
  waitpid($pid, 0);
  print $answers length($out), " $? ", length($err), "\n", $out, $err;
}

