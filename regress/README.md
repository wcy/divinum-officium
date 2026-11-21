# Regression check

`compare.pl` renders the pages listed in `pages.txt` with two trees of the
site, a base and a head, and reports what the head changes: the data files
it changes and their mistakes, the pages that fail, what each changed file
does alone, and the pages that differ, grouped by the change. The unit
tests in `t/` test parts of the code; this shows what a change does to the
finished pages.

The workflow `.github/workflows/regress.yml` runs it, with the unit tests,
on every pull request that touches `web/`, `t/` or `regress/`. The base is
the branch the pull request goes into. The pages are shared among eight
machines (`--shard K/8 --json FILE`), and a last job merges what they found
into one report (`--merge`). When nothing under `web/` or `regress/` has
changed, no page can change, and none is rendered. The report is in the run's summary
(the Summary link of the run under the pull request's Checks). The check
fails only when a unit test fails, when a page that renders in the base
fails in the pull request, or when a shard does not finish. A page that
only changes does not fail it.

## Running it

From the root of a checkout:

    git worktree add ../base master
    perl regress/compare.pl ../base . --jobs 8

`--markdown` writes the report in Markdown, as the run's summary has it. The pages are compared
in memory, and nothing is written. The clock is frozen (`lib/FixedTime.pm`)
and Perl's hash order fixed, so the same tree always gives the same page.
It needs `Algorithm::Diff` (in `cpanfile`).

Each page is rendered in a fork of a process that has the site's code
loaded (`serve.pl`, one for each tree and program folder): the modules,
and the files the scripts require, compiled but not run. The page's script
runs in the fork, and its requires run those files' code where a new
process would load them, so the page is the same as from a new process,
in about half the time. `--exec` renders each page in a new process, as
the site does; on all the pages of `pages.txt` the two give the same bytes.

## The report

It begins with the counts and a table of the scripts whose pages differ,
then:

1. **The data files** the change touches, each with its errors and
   warnings and what changed in it, section by section (`[Lectio4] -
   eunuchi + eunuch`).
2. **The pages that fail**, by error (below).
3. **What each change does alone** (below).
4. **The pages added for the changed data files**, and the changed data
   files that no page shows.
5. **The pages that differ**, in sections by script (`officium.pl`,
   `kalendar.pl`, `missa.pl`, …), so that a change to one kind of page does
   not hide the others. In each, every kind of change is listed once, with
   the number of pages it is on, an example and the pages; the 50 kinds of
   the most pages, then the count of the others. A kind is what a change
   does on any day: for the text, the words removed and added and the tag
   they are in (`- Dominica (in FONT)`); for the markup alone, the tags
   removed and added. So a change made on many days and titles is one kind,
   apart from the other changes on the same pages. An example links to the
   live site, which shows the base's page.

## The data files

Few of the data files show on the pages of the list: on all of them, 19% of
the 31,714 files under `web/www` are read at all (most of the Latin Office,
half the English, a quarter of the Mass, 1% of the other languages), and a
file read is not all shown (the Ordo reads a saint's title, not his
lessons). So the data files a change touches are also checked as text, and
pages are added that show them.

The check (`lib/DataCheck.pm`) lists each changed file with what changed in
each section. These are errors, which fail the check, with the file and
line in an annotation of the pull request's diff:

- text that is not UTF-8 (the site reads the files as UTF-8);
- a byte-order mark, or Windows line ends (CR LF), that the base did not
  have;
- a reference (`@Commune/C4:Lectio4`) on a line the change adds or alters,
  to a file or a section that no language has. It is looked for as the site
  looks for it: in the file's language, its parent, English and Latin; a
  Monastic, Cistercian or Dominican folder also in the Roman; in the
  Office's and the Mass's folders; and in the files that the referred file
  takes whole;
- a section the change removes while another file refers to it.

A removed section that no file refers to, and a file mostly rewritten, are
warnings.

The pages added (`lib/PagesFor.pm`, 200 at most) are, for a saint's or a
season's file, all the hours of its day, or its Mass, in the file's
language: the day and the versions are where a version's calendar
(`Tabulae/Kalendaria`) or a transfer table puts the file, else the day its
name gives (`05-12`, or `Pasc2-3` as the site's `DivinumOfficium::Date`
names the days), else the day of a file that refers to it. For a Commune,
the day of a saint that refers to it; for a psalm, the days of the week of
the third Sunday after the Epiphany, which say 149 of the 150 psalms; for
the martyrology of a day, Prime of the day before; for a transfer table,
the Ordo of a year that reads it, for the versions its changed lines name.
On a sample of 211 files spread over `web/www`, the pages added for each
read it for 188 (89%); no page is found for the Rule, the help, the chant
and the dioceses' folders.

## What each change does alone

When a change touches two files or more under `web/` (30 at most, else
folders), each is put back as in the base, alone, in a hard-linked copy of
the head, and the pages that fail, then enough of those that differ to show
each kind of change once (the lightest first, to a bound for each machine),
are rendered with it. What the head changes from
that copy is what that file's change does: the report gives it file by
file, and the pull request shows it as a notice on the file. So a line
changed among many (one line of `Main.pm` among the ten files of a new
Ordo) shows apart from the rest; a file that is the cause of a failure is
named; and a file that cannot be undone alone (the pages fail without it)
goes with other changes.

## When it fails

A page fails when its script exits with an error, prints no page, or is
still running after a minute (it is then stopped, and the other pages go
on). The report lists the failing pages under the error they give: the last
lines the script printed on its standard error, the same as from a new
process, with the tree's path as `TREE`:

    == 1. on 4 pages
        Undefined subroutine &main::nosuchsub called at TREE/web/cgi-bin/horas/specials.pl line 26.
      horas/officium.pl?version=Monastic%20-%201963&command=prayVespera&date=4-25-2026
      …

The pull request shows each error as an annotation with its checks; the
log of the report job and the run's summary have the list, and the log of
a shard names each failing page as it is found. The pages that fail in the
base and render in the pull request are listed apart, with the base's
error, and so are those that fail in both. None of these is counted among
the pages that differ.

When a shard does not finish (a module does not install, or the job runs
out of time), the report names it and the check fails; the shard's log says
why. If a worker of `compare.pl` stops, `compare.pl` names the page it was
on and exits with an error, so that no page is left out unnoticed.

## The pages

`pages.txt` has one page per line, the part of its URL after `cgi-bin/`.
`NAME = a | b` names a list, and a line with `$NAME` stands for one page per
value; `{a,b}` likewise. They are chosen to show as much as possible in few
pages:

1. **The calendar:** the Ordo of a whole year (`kalendar.pl`, `kmonth=14`)
   shows 365 days of precedence, commemorations, colours and notes on one
   page. The years are the ones that matter to each version: the earliest
   and the latest Easter (22 March 1818, 25 April 2038) in every version;
   then, version by version, the fewest years that show every transfer of
   `web/www/Tabulae/Transfer` (the tables of the dates of Easter, those of
   January and February in a leap year, and those of the Sunday letters)
   and every Sunday letter, so that each fixed feast falls on every day of
   the week. These are the years of St Joseph and the Annunciation in Holy
   Week or the Easter octave, of St Mark on Easter, of the feasts moved by
   the Ascension, Pentecost and Corpus Christi, and of the leap years'
   Januaries: 167 Ordos over 38 years, chosen by a greedy set cover over the
   years 1800-2300. Also the Kalendarium and the dioceses.
2. **The hours and the Mass:** for each version, the fewest days that show
   every kind of each hour and of the Mass at least once. The kinds are the
   parts of an hour and where each comes from, the number of psalms and of
   commemorations, the nocturns and the kinds of their lessons, the Te
   Deum, the concurrence of Vespers; for the Mass, its Gloria, Credo,
   sequence, alleluia or tract, preface, commemorations, orations and last
   Gospel. The days were picked once by a greedy set cover over the days of
   the same nine years. A day picked for three hours or more is one page of
   all the hours (`command=prayOmnes`), with Vespers also on its own page
   for the heading of its concurrence; otherwise each hour it was picked for
   is a page. And Vespers of every day from Christmas to the octave day of
   the Epiphany, in every version: the season's octaves, the Sunday within
   the octave, the Holy Name and the Epiphany change the office in ways
   these kinds do not tell apart.
3. **The rest of the site, once each:** the languages in either column, the
   votive offices and Masses, the options, the start page, the plain and
   compared offices and Masses, the popups.

When a change brings a new kind of day, add a page that shows it.
