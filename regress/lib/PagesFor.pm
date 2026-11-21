package PagesFor;

# Pages that show the data files a change touches, so that a changed text is
# rendered even when no page of the list shows it:
#
#   - a saint's file (Sancti) or a season's (Tempora): all the hours of its
#     day, or its Mass, in the file's language. The day and the versions are
#     where a version's calendar (Tabulae/Kalendaria) or a transfer table
#     puts the file; else the day its name gives ("05-12"; "Pasc2-3", found
#     with the site's own DivinumOfficium::Date); else the day of a file that
#     refers to it ("@Sancti/12-12a");
#   - a Commune: the day of a saint that refers to it;
#   - the psalter, the Mass's Ordo: an ordinary Sunday and weekday;
#   - the martyrology of a day: Prime of the day before, which reads it;
#   - a table (Tabulae): the Ordo of a year that reads it, for the versions
#     its changed lines name.
#
#   my @pages = pages_for($base, $head, \@files);   # [page, file] pairs
#
# A file that is none of these (the appendix, the Rule...) gives no page.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(pages_for);

# the versions first tried for each family of folders (Sancti, SanctiM...)
our %OFFICE = (
  '' => ['Divino Afflatu - 1954', 'Rubrics 1960 - 1960'],
  M => ['Monastic - 1963'],
  Cist => ['Monastic Tridentinum Cisterciensis 1951'],
  OP => ['Ordo Praedicatorum - 1962'],
);
our @MASS = ('Divino Afflatu - 1954', 'Rubrics 1960 - 1960');

# the Mass's name of an Office's version, where it has a Mass
my %MASS_NAME = (
  map({ $_ => $_ } 'Tridentine - 1570',
    'Divino Afflatu - 1939',
    'Divino Afflatu - 1954',
    'Reduced - 1955',
    'Rubrics 1960 - 1960',
  ),
  'Tridentine - 1888' => 'Tridentine - 1910',
  'Tridentine - 1906' => 'Tridentine - 1910',
  'Rubrics 1960 - 2020 USA' => 'Rubrics 1960 Newcalendar',
);

my $CODE = qr/(?:Adv|Epi|Quadp|Quad|Pasc|PentEpi|Pent)\d+-\d|Nat\d+-\d|Nat\d+|\d{3}-\d/;

sub pages_for {
  my ($base, $head, $files) = @_;
  my $ctx = {
    head => $head,
    base => $base,
  };
  my (@out, %seen);

  for my $file (@$files) {
    for my $page (pages_of($ctx, $file)) {
      push @out, [$page, $file] unless $seen{$page}++;
    }
  }
  return @out;
}

sub enc { $_[0] =~ s/ /%20/gr }

sub lang_param {
  my ($lang, $kind) = @_;
  return '' if $lang eq 'Latin';
  return '&psalmvar=1' if $lang eq 'Latin-Bea' && $kind eq 'horas';
  return "&lang2=$lang";
}

sub page_at {
  my ($kind, $lang, $version, $m, $d, $y, $extra) = @_;
  return
      ($kind eq 'missa' ? 'missa/missa.pl?' : 'horas/officium.pl?')
    . 'version='
    . enc($version)
    . ($kind eq 'missa' ? '' : '&command=' . ($extra // 'prayOmnes'))
    . "&date=$m-$d-$y"
    . lang_param($lang, $kind)
    . ($kind eq 'missa' && $extra ? $extra : '');
}

sub pages_of {
  my ($ctx, $file) = @_;
  return () unless $file =~ m{^web/www/(.*)\.txt$};
  my $path = $1;

  return tables($ctx, $1) if $path =~ m{^Tabulae/(.*)$};
  my ($kind, $lang, $folder, $name) = $path =~ m{^(horas|missa)/([^/]+)/([^/]+)/(.+)$} or return ();
  my $at = sub {
    my $extra = shift;
    return map { page_at($kind, $lang, @$_, $extra) } @_;
  };

  if ($folder =~ /^(Sancti|Tempora|Commune)(M|Cist|OP)?$/) {
    return $at->(undef, days_of($ctx, $kind, "$1" . ($2 // ''), $name, 0));
  }

  my $ordinary = sub {
    my $version = shift;
    return map { [$version, @{tempora($ctx)->{$_}}] } grep { tempora($ctx)->{$_} } qw(Pent05-0 Pent05-3);
  };

  # a psalm: the week of the third Sunday after Epiphany, which says 149
  # of the 150 psalms with the psalter of 1911; the rest of the psalter: a
  # Sunday and a weekday
  if ($kind eq 'horas' && $folder eq 'Psalterium') {
    return $at->(
      undef, map { [$OFFICE{''}[0], @{tempora($ctx)->{$_}}] } grep { tempora($ctx)->{$_} } map {"Epi3-$_"} 0 .. 6,
    ) if $name =~ m{^Psalmorum/};
    return $at->(undef, $ordinary->($OFFICE{''}[0]));
  }

  if ($kind eq 'missa' && $folder eq 'Ordo') {
    return 'missa/mpopup.pl?popup=' . $name . '&lang1=Latin&lang2=' . ($lang eq 'Latin' ? 'English' : $lang)
      if $name =~ /^(?:Ante|Post)$/;
    return $at->(undef, $ordinary->('1965-1967')) if $name eq 'Ordo67';
    return $at->(undef, $ordinary->('Rubrics 1960 Newcalendar')) if $name eq 'OrdoN';
    return $at->('&solemn=1', $ordinary->($MASS[0])) if $name eq 'OrdoS';
    return $at->(undef, $ordinary->($MASS[0]));
  }

  # the martyrology of a day is read at Prime the day before
  if ($kind eq 'horas' && $folder eq 'Martyrologium' && $name =~ /^(\d\d)-(\d\d)$/) {
    my ($m, $d, $y) = saint_day($ctx, $1, $2);

    if ($d > 1) {
      $d--;
    } elsif ($m > 1) {
      $m--;
      $d = days_in($m, $y);
    } else {
      ($m, $d, $y) = (12, 31, $y - 1);
    }
    return $at->('prayPrima', [$OFFICE{''}[0], $m, $d, $y]);
  }
  return ();
}

sub family_of {
  local $_ = shift;
  return /Cisterciensis/ ? 'Cist' : /Monastic/ ? 'M' : /Praedicatorum/ ? 'OP' : '';
}

# The days and versions ([version, month, day, year], two at most) whose
# office or Mass reads a file of the saints, the seasons or the Commune
# (FOLDER: Sancti, SanctiM, Tempora, CommuneOP...).
sub days_of {
  my ($ctx, $kind, $folder, $name, $depth) = @_;
  my ($family, $suffix) = $folder =~ /^(Sancti|Tempora|Commune)(.*)$/;
  my @first = $kind eq 'missa' ? @MASS : @{$OFFICE{$suffix} // $OFFICE{''}};
  my $with = sub {
    my @date = @_;
    map { [$_, @date] } @first;
  };

  # its name is its day
  return $with->(saint_day($ctx, $1, $2)) if $family eq 'Sancti' && $name =~ /^(\d\d)-(\d\d)$/ && "$1-$2" ne '01-00';
  return $with->(@{tempora($ctx)->{$name}}) if $family eq 'Tempora' && tempora($ctx)->{$name};

  # where a calendar or a transfer table puts it
  if ($family ne 'Commune') {

    # the versions that read the folder: every version falls back to the
    # Roman folders, the Cistercian to the Monastic
    my %reads = (
      '' => ['', 'M', 'Cist', 'OP'],
      M => ['M', 'Cist'],
      Cist => ['Cist'],
      OP => ['OP'],
    );
    my %readers = map { $_ => 1 } @{$reads{$suffix} // []};
    my @routes = grep { $readers{family_of($_->[0])} } @{routes($ctx)->{$name} // []};
    my @mine = grep { family_of($_->[0]) eq $suffix } @routes;
    @routes = @mine if @mine;
    @routes = grep { $_->[0] = $MASS_NAME{$_->[0]} } map { [@$_] } @routes if $kind eq 'missa';
    my %rank = map { $first[$_] => $_ } 0 .. $#first;
    my (%v, @out);

    for my $r (sort { ($rank{$a->[0]} // 99) <=> ($rank{$b->[0]} // 99) || $a->[0] cmp $b->[0] } @routes) {
      next if $v{$r->[0]}++;
      my ($version, $m, $d, $y) = @$r;
      push @out, [$version, $y ? ($m, $d, $y) : saint_day($ctx, $m, $d)];
      last if @out == 2;
    }
    return @out if @out;
  }

  # the day of a file that refers to it
  if ($depth < 2) {
    for my $from (@{referrers($ctx, $kind)->{"$folder/$name"} // []}) {
      my ($f, $n) = split m{/}, $from, 2;
      my @days = days_of($ctx, $kind, $f, $n, $depth + 1);
      return @days if @days;
    }
  }

  # a variant of a day's file (12-24so, Pasc2-3Feria): that day
  return $with->(saint_day($ctx, $1, $2)) if $family eq 'Sancti' && $name =~ /^(\d\d)-(\d\d)/;
  return $with->(@{tempora($ctx)->{$1}}) if $family eq 'Tempora' && $name =~ /^($CODE)/ && tempora($ctx)->{$1};
  return ();
}

# Where the versions' calendars and the transfer tables put each file of the
# saints and the seasons: name => [[version, month, day, year or undef]...].
# A calendar's line is "MM-DD=file~file=title=rank="; a table's
# "MM-DD=file~file;;codes", read in a year that reads the table.
sub routes {
  my $ctx = shift;
  return $ctx->{routes} if $ctx->{routes};
  my $data = versions_data($ctx);
  my %routes;
  my $read = sub {
    open(my $fh, '<:encoding(UTF-8)', shift) or return ();
    map {s/\s+$//r} <$fh>;
  };

  for my $v (sort keys %$data) {
    for ($read->("$ctx->{head}/web/www/Tabulae/Kalendaria/$data->{$v}{kalendar}.txt")) {
      my ($m, $d, $names) = /^(\d\d)-(\d\d)=([^=]+)=/ or next;
      ($m, $d) = (@{tempora($ctx)->{'Nat2-0'} // [1, 2]})[0, 1] if "$m-$d" eq '01-00';    # the Holy Name
      push @{$routes{$_}}, [$v, $m + 0, $d + 0] for split /~/, $names;
    }
  }

  # the Tempora tables: "Tempora/Adv4-4=Tempora/Adv4-4o;;1570", the second
  # file read on the first's day by the versions named
  for ($read->("$ctx->{head}/web/www/Tabulae/Tempora/Generale.txt")) {
    my ($line, $codes) = split /\s*;;\s*/;
    my ($code, $names) = ($line // '') =~ m{^Tempora\w*/([^=]+)=(.+)$} or next;
    my $date = tempora($ctx)->{$code} or next;
    my @v = grep {
      my $c = $data->{$_}{transfer};
      !$codes || grep { $_ eq $c } split ' ', $codes
    } sort keys %$data;

    for my $n (map {s{^\w+/}{}r} split /~/, $names) {
      push @{$routes{$n}}, [$_, @$date] for @v;
    }
  }

  for my $type ('Transfer', 'Stransfer') {
    for my $table (sort glob("$ctx->{head}/web/www/Tabulae/$type/*.txt")) {
      my ($name) = $table =~ m{([^/]+)\.txt$};
      my $y = table_year($ctx, $name) or next;

      for ($read->($table)) {
        my ($line, $codes) = split /\s*;;\s*/;
        my ($m, $d, $names) = ($line // '') =~ /^(\d\d)-(\d\d)=(.+)$/ or next;
        my @v = grep {
          my $c = $data->{$_}{lc $type};
          !$codes || grep { $_ eq $c } split ' ', $codes
        } sort keys %$data;

        for my $n (split /~/, $names) {
          push @{$routes{$n}}, [$_, $m + 0, $d + 0, $y] for @v;
        }
      }
    }
  }
  return $ctx->{routes} = \%routes;
}

# The files in Latin that refer to each file ("@Sancti/12-12a", and "vide
# C4a" for the Commune of their family): "Sancti/12-12a" => ["Sancti/12-13"...].
sub referrers {
  my ($ctx, $kind) = @_;
  return $ctx->{referrers}{$kind} if $ctx->{referrers}{$kind};
  my %from;

  for my $file (sort glob("$ctx->{head}/web/www/$kind/Latin/{Sancti,Tempora,Commune}*/*.txt")) {
    my ($folder, $name) = $file =~ m{/([^/]+)/([^/]+)\.txt$};
    my ($suffix) = $folder =~ /^(?:Sancti|Tempora|Commune)(.*)$/;
    open(my $fh, '<:encoding(UTF-8)', $file) or next;
    local $/;
    my $text = <$fh>;
    my %to;
    $to{$1} = 1 while $text =~ m{\@((?:Sancti|Tempora|Commune)\w*/[^:\s]+)}g;
    $to{"Commune$suffix/$1"} = 1 while $text =~ m{\bvide\s+(C[\w-]+)}g;
    push @{$from{$_}}, "$folder/$name" for grep { $_ ne "$folder/$name" } keys %to;
  }
  return $ctx->{referrers}{$kind} = \%from;
}

sub days_in {
  my ($m, $y) = @_;
  return (31, (leap($y) ? 29 : 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[$m - 1];
}
sub leap { my $y = shift; !($y % 4) && ($y % 100 || !($y % 400)) }

# The site's date functions, from the tree being tested.
sub date_module {
  my $ctx = shift;
  return $ctx->{date} if exists $ctx->{date};
  local @INC = ("$ctx->{head}/web/cgi-bin", @INC);
  $ctx->{date} = eval { require DivinumOfficium::Date; 1 } ? 'DivinumOfficium::Date' : undef;
  return $ctx->{date};
}

# The first year from 2026 in which a day of the saints is said: not a
# Sunday, nor in Holy Week or the octave of Easter.
sub saint_day {
  my ($ctx, $m, $d) = @_;
  ($m, $d) = ($m + 0, $d + 0);
  my $date = date_module($ctx) or return ($m, $d, 2026);
  no strict 'refs';

  for my $y (2026 .. 2045) {
    next if $m == 2 && $d == 29 && !leap($y);
    next if &{"${date}::day_of_week"}($d, $m, $y) == 0;
    my $t = &{"${date}::date_to_ydays"}($d, $m, $y);
    my $easter = &{"${date}::date_to_ydays"}(&{"${date}::geteaster"}($y));
    next if $t >= $easter - 7 && $t <= $easter + 7;
    return ($m, $d, $y);
  }
  return ($m, $d, 2028);
}

# The first day from 2026 that each Tempora code names, as the site names
# them (getweek, and monthday for the weeks of August to November).
sub tempora {
  my $ctx = shift;
  return $ctx->{tempora} if $ctx->{tempora};
  my %date;
  my $date = date_module($ctx) or return $ctx->{tempora} = {};
  no strict 'refs';

  for my $y (2026 .. 2045) {
    for my $t (1 .. (leap($y) ? 366 : 365)) {
      my ($d, $m) = &{"${date}::ydays_to_date"}($t, $y);
      my $dow = &{"${date}::day_of_week"}($d, $m, $y);
      my @codes;

      for my $missa (0, 1) {
        my $week = &{"${date}::getweek"}($d, $m, $y, 0, $missa);
        push @codes, $week =~ /^Nat/ ? $week : "$week-$dow";
      }
      push @codes, 'Nat1-0' if $m == 12 && $d >= 26 && $dow == 0;
      push @codes, 'Nat2-0' if $m == 1 && $d >= 2 && $d <= 5 && $dow == 0;
      push @codes, grep {$_} map { &{"${date}::monthday"}($d, $m, $y, $_, 0) } 0, 1;
      $date{$_} //= [$m, $d, $y] for @codes;
    }
  }
  return $ctx->{tempora} = \%date;
}

# Tabulae: the Ordo of the year. A transfer table (Transfer, Stransfer, by
# Easter date or Sunday letter, perhaps in a diocese's folder) is read in the
# years whose Easter gives its name, for the versions its changed lines name;
# a calendar (Kalendaria), by the versions that use it.
sub tables {
  my ($ctx, $path) = @_;
  my $data = versions_data($ctx);
  my $ordo = sub {
    my ($y, $dio, @v) = @_;
    return
      map { 'horas/kalendar.pl?version=' . enc($_) . "&kmonth=14&kyear=$y" . ($dio ? "&dioecesis=$dio" : '') } @v;
  };

  if ($path =~ m{^Kalendaria/(.+)$}) {
    my $code = $1;
    return $ordo->(2026, '', grep { $data->{$_}{kalendar} eq $code } sort keys %$data);
  }

  if ($path =~ m{^(Transfer|Stransfer)/(?:([^/]+)/)?([^/]+)$}) {
    my ($type, $dio, $name) = ($1, $2, $3);
    my $y = table_year($ctx, $name) or return ();
    my @codes = changed_codes($ctx, "web/www/Tabulae/$path.txt");
    my @v = sort grep {
      my $c = $data->{$_}{lc $type};
      !@codes || grep { $_ eq '*' || $_ eq $c } @codes;
    } keys %$data;
    return $ordo->($y, $dio // '', @v);
  }

  return $ordo->(2026, $1 eq 'Generale' ? '' : $1, sort keys %$data) if $path =~ m{^Tempora/(.+)$};
  return $ordo->(2026, '', sort keys %$data);    # data.txt
}

# the Office's versions and their tables, from Tabulae/data.txt
sub versions_data {
  my $ctx = shift;
  return $ctx->{data} if $ctx->{data};
  my %data;
  open(my $fh, '<:encoding(UTF-8)', "$ctx->{head}/web/www/Tabulae/data.txt") or return $ctx->{data} = {};

  while (my $line = <$fh>) {
    chomp $line;
    last if $line =~ /^#/;    # the Mass's names follow
    next if $line =~ /^version,/;
    my ($v, $k, $t, $s) = split /,/, $line;
    $data{$v} = {
      kalendar => $k // '',
      transfer => $t // '',
      stransfer => $s // '',
    } if $v;
  }
  return $ctx->{data} = \%data;
}

# The first year from 2026 whose transfer tables include NAME ("322",
# "322bis", "e"), by the rule of DivinumOfficium::Directorium.
sub table_year {
  my ($ctx, $name) = @_;
  return $ctx->{year}{$name} if exists $ctx->{year}{$name};
  my $date = date_module($ctx) or return;
  no strict 'refs';

  for my $y (2026 .. 2300, 1583 .. 2025) {

    my @e = &{"${date}::geteaster"}($y);
    my $easter = $e[1] * 100 + $e[0];
    my @letters = ('a' .. 'g');
    my $letter = ($easter - 319 + ($e[1] == 4 ? 1 : 0)) % 7;
    my @names = ($letters[$letter], $easter);

    if (leap($y)) {
      my $next = $easter + 1;
      $next = 401 if $next == 332;
      push @names, "${easter}bis", $letters[$letter - 6], $next;
    }
    return $ctx->{year}{$name} = $y if grep { $_ eq $name } @names;
  }
  return $ctx->{year}{$name} = undef;
}

# The version codes of the lines a change adds or removes in a transfer
# table ("02-24=02-25;;1570 1888"); '*' for a line for all versions.
sub changed_codes {
  my ($ctx, $file) = @_;
  my %lines;

  for my $tree ($ctx->{base}, $ctx->{head}) {
    open(my $fh, '<', "$tree/$file") or next;
    my %once = map { s/\s+$//r => 1 } <$fh>;
    $lines{$_}++ for keys %once;
  }
  my %codes;

  for my $line (grep { $lines{$_} == 1 && /\S/ } keys %lines) {
    my (undef, $ver) = split(/\s*;;\s*/, $line);
    $codes{$_} = 1 for $ver ? split(' ', $ver) : '*';
  }
  return sort keys %codes;
}

1;
