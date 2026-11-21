package DataCheck;

# Checks the data files a change touches (the .txt files under web/www)
# without rendering them: what the change does to each, section by section,
# and the changes that are surely mistakes.
#
#   my @checked = check_data($base, $head, \@files);
#
# Each is {file, status (added, removed, changed), sections => [...],
# errors => [[line, text]...], warnings => [[line, text]...]}; a line of 0
# is the file as a whole.
#
# Errors: text that is not UTF-8; a byte-order mark or Windows line ends
# (CR LF) that the base did not have; a reference ("@Commune/C4:Lectio4")
# on a line the change adds or alters, to a file or a section that no
# language has; a section the change removes while another file refers to
# it. Warnings: a removed section no file refers to; most of the file
# rewritten.
#
# A reference is looked for as the site looks for it: in the file's
# language, its parent language (Polski for Polski-Newer), English and
# Latin; a Monastic, Cistercian or Dominican folder (SanctiM) also in the
# Roman one (Sancti), a Cistercian one in the Monastic; in the Office's
# folders and the Mass's (the Monastic Office's Gospel is the Mass's); and a section also in the files that the
# referred file takes whole ("@Commune/C4" before its first section).

use strict;
use warnings;
use Encode ();
use Exporter qw(import);

our @EXPORT_OK = qw(check_data);

my $SECTION = qr/^\s*\[([\pL\pN_ #,:-]+)\](.*)$/;
my $INCLUSION = qr/^\s*\@([^\n:]+)?(?::([^\n:]+?))?[^\S\n\r]*(?::(.*))?$/;

sub check_data {
  my ($base, $head, $files) = @_;
  my $ctx = {
    base => $base,
    head => $head,
  };
  return map { check_file($ctx, $_) } grep {m{^web/www/.*\.txt$}} @$files;
}

sub slurp {
  my $path = shift;
  open(my $fh, '<:raw', $path) or return undef;
  local $/;
  return scalar <$fh>;
}

sub check_file {
  my ($ctx, $file) = @_;
  my ($old, $new) = map { slurp("$_/$file") } $ctx->{base}, $ctx->{head};
  my %r = (
    file => $file,
    errors => [],
    warnings => [],
    sections => [],
  );
  $r{status} = !defined $old ? 'added' : !defined $new ? 'removed' : 'changed';
  return \%r unless defined $new;
  $old //= '';
  my @old = split /\n/, $old, -1;
  my @new = split /\n/, $new, -1;

  # the bytes
  my $bad = sub {
    my $line = shift;
    my $copy = $line;
    return !eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK); 1 };
  };
  my %old_lines = map { $_ => 1 } @old;

  for my $i (0 .. $#new) {
    next unless $bad->($new[$i]) && !$old_lines{$new[$i]};
    push @{$r{errors}}, [$i + 1, 'is not UTF-8 (the site reads the files as UTF-8)'];
    last;
  }
  push @{$r{errors}}, [1, 'begins with a byte-order mark'] if $new =~ /^\xEF\xBB\xBF/ && $old !~ /^\xEF\xBB\xBF/;
  my $cr = grep {/\r$/} @old;

  if ((grep {/\r$/} @new) > $cr) {
    my ($i) = grep { $new[$_] =~ /\r$/ && !$old_lines{$new[$_]} } 0 .. $#new;
    push @{$r{errors}}, [($i // 0) + 1, 'has a Windows line end (CR LF)'];
  }

  # the sections, as text
  my $text = sub { my $b = shift; Encode::decode('UTF-8', $b, Encode::FB_DEFAULT) =~ s/\r$//mgr };
  my ($os, $ns) = map { sections($text->($_)) } $old, $new;
  my %names = map { $_->{name} => 1 } values %$ns;

  for my $key (sort { ($os->{$a} // $ns->{$a})->{line} <=> ($os->{$b} // $ns->{$b})->{line} } keys %{{%$os, %$ns}}) {
    my ($o, $n) = ($os->{$key}, $ns->{$key});

    if (!$o) {
      push @{$r{sections}}, "[$key] added" if $r{status} eq 'changed';
    } elsif (!$n) {
      push @{$r{sections}}, "[$key] removed";
      next if $names{$o->{name}};    # still there under another condition
      my @from = referred_by($ctx, $file, $o->{name});
      push @{$r{@from ? 'errors' : 'warnings'}}, [
          0,
          "removes [$key]"
          . (@from ? ", which $from[0] refers to" . (@from > 1 ? ' (and ' . (@from - 1) . ' more)' : '') : ''),
        ];
    } elsif ($o->{body} ne $n->{body}) {
      push @{$r{sections}}, "[$key] " . words($o->{body}, $n->{body});
    }
  }

  # the references on the lines it adds or alters
  require Algorithm::Diff;
  my %changed;
  my ($ot, $nt) = map { [split /\n/, $text->($_), -1] } $old, $new;

  for my $hunk (Algorithm::Diff::diff($ot, $nt)) {
    $changed{$_->[1]} = 1 for grep { $_->[0] eq '+' } @$hunk;
  }
  my $key = '__preamble';

  for my $i (0 .. $#$nt) {
    my $line = $nt->[$i];

    if ($line =~ $SECTION) {
      $key = $1;
      next;
    }
    next unless $changed{$i} && $line =~ $INCLUSION && $key ne '__preamble';
    my ($to, $section) = ($1, $2 // $key);
    my $problem = unresolved($ctx, $file, $to, $section);
    push @{$r{errors}}, [$i + 1, $problem] if $problem;
  }

  # most of it rewritten
  my $kept = 0;
  Algorithm::Diff::traverse_sequences($ot, $nt, {MATCH => sub { $kept++ }});
  my $removed = @$ot - $kept;
  push @{$r{warnings}}, [0, sprintf('changes %d%% of its lines', 100 * $removed / @$ot)]
    if $r{status} eq 'changed' && @$ot >= 10 && $removed / @$ot > 0.5;
  return \%r;
}

# The sections of a file's text: "name condition" => {name, line, body}.
sub sections {
  my $text = shift;
  my %s;
  my ($key, $line) = ('__preamble', 0);

  for my $l (split /\n/, $text) {
    $line++;

    if ($l =~ $SECTION) {
      my ($name, $cond) = ($1, $2);
      $cond =~ s/^\s+|\s+$//g;
      $key = $cond ? "$name $cond" : $name;
      $s{$key} = {
        name => $name,
        line => $line,
        body => '',
      };
      next;
    }
    $s{$key} //= {
      name => $key,
      line => $line,
      body => '',
    };
    $s{$key}{body} .= "$l\n";
  }
  return \%s;
}

# what changed in a section, in words: "- eunuchi + eunuch"
sub words {
  my ($old, $new) = @_;
  return 'spaces only' if join(' ', split ' ', $old) eq join(' ', split ' ', $new);
  require Algorithm::Diff;
  my @a = split ' ', $old;
  my @b = split ' ', $new;
  my @out;

  for my $hunk (Algorithm::Diff::diff(\@a, \@b)) {
    my $minus = join(' ', map { $a[$_->[1]] } grep { $_->[0] eq '-' } @$hunk);
    my $plus = join(' ', map { $b[$_->[1]] } grep { $_->[0] eq '+' } @$hunk);
    push @out, join(' ', ($minus ne '' ? "- $minus" : ()), ($plus ne '' ? "+ $plus" : ()));
  }
  my $s = join('; ', @out[0 .. ($#out < 2 ? $#out : 2)]) . (@out > 3 ? '; …' : '');
  return length $s > 200 ? substr($s, 0, 200) . '…' : $s;
}

# The places a reference from FILE to TO (as written after "@") may be:
# [path, ...] in the order the site would try them.
sub candidates {
  my ($ctx, $file, $to) = @_;
  my ($kind, $lang, $rel) = $file =~ m{^web/www/(horas|missa)/([^/]+)/(.+)\.txt$} or return ();
  $to = $rel if !defined $to || $to eq '';
  my %seen;
  my @langs = grep { !$seen{$_}++ } $lang, $lang =~ s/-.*//r, 'English', 'Latin';
  my @names = ($to);
  push @names, "$1/$3" if $to =~ m{^(Sancti|Tempora|Commune)(M|Cist|OP)/(.+)$};
  push @names, "$1M/$2" if $to =~ m{^(Sancti|Tempora|Commune)Cist/(.+)$};
  my @kinds = $kind eq 'missa' ? ('missa', 'horas') : ('horas', 'missa');
  %seen = ();
  return grep { !$seen{$_}++ } map {
    my $k = $_;
    map {
      my $l = $_;
      map {"web/www/$k/$l/$_.txt"} @names
    } @langs
  } @kinds;
}

# The section names a file has, with those of the files it takes whole.
sub names_in {
  my ($ctx, $path, $depth) = @_;
  return $ctx->{names}{$path} if $ctx->{names}{$path};
  my $bytes = slurp("$ctx->{head}/$path") // return {};
  my $text = Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT);
  my %names;

  for my $l (split /\n/, $text) {
    if ($l =~ $SECTION) {
      $names{$1} = 1;
      next;
    }
  }

  if (($depth // 0) < 4 && $text =~ /\A((?:(?!^\s*\[).*\n)*)/m) {
    for my $line (split /\n/, $1) {
      next unless $line =~ /^\s*\@([^\n:]+)/;
      my ($inc) = grep { -f "$ctx->{head}/$_" } candidates($ctx, $path, $1);
      %names = (%names, %{names_in($ctx, $inc, ($depth // 0) + 1)}) if $inc;
    }
  }
  return $ctx->{names}{$path} = \%names;
}

# Why a reference does not resolve, or undef.
sub unresolved {
  my ($ctx, $file, $to, $section) = @_;
  my @found = grep { -f "$ctx->{head}/$_" } candidates($ctx, $file, $to);
  return "refers to $to, which no language has" unless @found;
  return if grep { names_in($ctx, $_)->{$section} } @found;
  return 'refers to [' . $section . '] of ' . ($to // 'itself') . ', which it does not have';
}

# The files that refer to a section of FILE: "@Sancti/05-12:Lectio4", or
# "@Sancti/05-12" in a section of that name. Those of its language, and of
# every language when it is Latin, which they all fall back on.
sub referred_by {
  my ($ctx, $file, $name) = @_;
  my ($kind, $lang, $rel) = $file =~ m{^web/www/(horas|missa)/([^/]+)/(.+)\.txt$} or return ();
  my $index = $ctx->{refs}{"$kind/$lang"} //= do {
    my %refs;

    for my $path (glob("$ctx->{head}/web/www/$kind/" . ($lang eq 'Latin' ? '*' : $lang) . '/*/*.txt')) {
      my $bytes = slurp($path) // next;
      next if index($bytes, '@') < 0;
      my ($from) = $path =~ m{web/www/[^/]+/(.+)\.txt$};
      my ($own) = $from =~ m{^[^/]+/(.+)$};
      my $key = '__preamble';

      for my $l (split /\n/, Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT)) {
        if ($l =~ $SECTION) {
          $key = $1;
          next;
        }
        next unless $l =~ $INCLUSION && $key ne '__preamble';
        my ($to, $section) = ($1 // $own, $2 // $key);
        push @{$refs{"$to:$section"}}, $from;
      }
    }
    \%refs;
  };
  my %seen;
  my @from = grep { !$seen{$_}++ && $_ ne "$lang/$rel" } @{$index->{"$rel:$name"} // []};
  return ((grep { index($_, "$lang/") == 0 } @from), (grep { index($_, "$lang/") != 0 } @from))
    ;    # its own language first
}

1;
