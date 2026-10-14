# terminfo

Reads the compiled terminfo binary format. One C11 file, no ncurses and
no libtinfo: the point of the exercise is to read the bytes.

```
$ ./terminfo -i /usr/share/terminfo/x/xterm
magic 0432
numsize 2
names 48
bools 38
nums 15
strs 413
strtable 1552
extbools 3
extnums 0
extstrs 86
extitems 175
exttable 1107
name xterm|xterm terminal emulator (X Window System)

$ ./terminfo -p /usr/share/terminfo/x/xterm 3 4 | head -3
p csr 1b5b343b3572
p hpa 1b5b3447
p cup 1b5b343b3548

$ make test
40 passed, 0 failed
```

## The part a reader cannot get from the file

A compiled terminfo file stores capabilities positionally. The name of
the capability at index 0 of the boolean array is not in the file. It is in
a table every reader is expected to already have, in ncurses' order.

So a reader can parse every byte of the format correctly and still be
completely wrong, by holding that table in a different order, and nothing
about the file will say so. That failure mode is invisible to any test that
only checks the file parsed.

The tables here were not typed out from a document. They were derived
from two things on this machine that we do not control:

- `/usr/include/term.h`, which fixes the long name at every index
  (`#define auto_left_margin CUR Booleans[0]`).
- `tic` itself, asked where it puts a given short name: compile a probe
  entry `probe, <name>,` and read back the resulting boolean count, which is
  the index plus one.

`t/derive-caps.py` regenerates exactly what is pasted into `terminfo.c`, so
the tables are reproducible, not trusted.

## The oracle is ncurses, as a subprocess

`infocmp` is asked what every capability of every terminal on this machine
should be, and the answer is compared value by value:

```
corpus (44 compiled terminal descriptions under /usr/share/terminfo)
legacy format (0432) read: 39 terminals
extended-number format (01036) read: 5 terminals
booleans are infocmp's, extended ones included (344 across 44 terminals)
numbers are infocmp's (211 across all 44 terminals, 5 of them 32-bit)
numbers: 5 values exceed 32767, which a 16-bit decode could not represent
string capabilities are infocmp's, byte for byte (5259 across 44 terminals)
strings: 6 are defined as the EMPTY string, which is not the same as absent
cancelled capabilities are infocmp's (9 across 44 terminals)
cancelled: 9 exist, so -2 is distinguished from -1 on real data
extended capabilities are infocmp -x's (734 across 29 of 44 terminals)
parameterised strings evaluate to tput's bytes (3834 evaluations, 43 terminals, 6 parameter tuples)
the operators no real entry uses evaluate to tput's bytes too (32 evaluations on a tic-compiled probe)
```

Every capability value the harness compares comes from `infocmp`, except
the evaluated ones, which come from `tput`. Both directions, never from a
number anybody worked out by hand. The floors are the exception and are
hand-written on purpose: at least 30 terminals, 200 booleans, 100 numbers,
4000 strings, 400 extended capabilities, 3000 evaluations and 15 operators
reached, and they exist so that a corpus too thin to prove anything
cannot pass. They are reported as a thin
corpus, not as a disagreement, because the combined form used to print
"booleans: 0 terminals disagree with infocmp, 191 compared" as a failure.

(This paragraph used to say nothing in the harness compares against a
hand-worked number, which the floors contradict.)

## Both number widths, and the value that proves it

Magic 0432 stores numeric capabilities as signed 16-bit integers; magic
01036 stores them as signed 32-bit integers and is otherwise identical. The
width comes from the header's magic, not from guessing at the
section size.

The assertion that matters is not that the wide values agree. It is that
some value could not have been read any other way:

```
numbers: 5 values exceed 32767, which a 16-bit decode could not represent
```

`pairs#65536` on a 256-colour terminal is the usual one. Without that
check, a reader that quietly fell back to 16 bits would still agree with
`infocmp` on every number small enough to fit, which is almost all of them.

This replaced the weakest assertion the harness had: it used to skip every
magic 01036 file and assert that the skip count was exactly 5, a hardcoded
fact about *this machine* and true nowhere else. Reading them
deleted the assertion instead of making it more precise.

## Two sentinels, not one

ncurses stores two different absent-markers in the number array: `-1` for
ABSENT and `-2` for CANCELLED. A reader that folds them together parses the
file correctly and loses a distinction `infocmp` prints, so they are kept
apart.

## Padding is a one-byte bug that still parses

Between sections the file is padded to an even byte boundary. Getting it
wrong shifts every number, every string offset and the whole extended
section by exactly one byte, and the result is still a file that parses,
with plausible-looking wrong values. That is why it has its own deliberate
sabotage in the harness instead of being left to the value comparison.

## Strings are compared as bytes, not as notation

5259 string capabilities across 44 terminals, byte for byte against
`infocmp -x`. The comparison is in hex, and that is the decision worth
explaining.

A string capability is arbitrary bytes, and terminfo's source notation has
several spellings for the same byte: `\E`, `\e` and `\033` are all ESC.
Printing that notation from the reader under test and diffing the text would
compare `infocmp` against an imitation of itself, and would pass or fail on
spelling, not on bytes. So `terminfo -d` emits hex, and
`t/caps-hex.py` decodes `infocmp`'s notation with a decoder that shares
nothing with the reader: one parses escape sequences out of text, the other
walks an offset table in a binary file. A bug common to both is not a bug
either could hide.

Three things the comparison turned up, none of which was a bug in the
reader:

`acsc` is the one capability `infocmp` does not print as stored. It is a
sequence of (from, to) byte pairs, and `infocmp` *sorts* them. Three
terminals here: `hurd` and two `rxvt-unicode` variants, store them in an
order it does not reproduce, with the identical multiset of pairs. Both
sides are normalised through one function, so the comparison is between the
set of pairs, the thing `acsc` means. Comparing the order would assert
something `term(5)` does not promise.

A capability can be defined as the empty string, and that is not the same
as being absent. `Eterm` defines `smkx` and `rmkx` that way. The first
version of the comparison used `split()`, which collapses an empty field, and
the two sides then disagreed about a capability both had read correctly. Six
of them exist and the count is asserted.

Cancellation needed its own section, and a mutation found out why.
Making the reader treat `-2` (cancelled) as `-1` (absent) survived the
string comparison, because a cancelled capability is emitted as `s@` and the
comparison only looked at `s ` lines. Nine cancelled capabilities exist in
this corpus across booleans, numbers and strings, `infocmp` prints all three
classes as `name@`, and they are now compared as one set. The hole was real,
not theoretical.

### Two mutants still survive, and they are honest

Both are malformed-file cases, and no file in this corpus is malformed:

- an offset exactly equal to the table size, accepted instead of refused
- `strlen` instead of a `memchr` bounded by the table, so an unterminated
  string at the table's end would read past it

They are untested machinery, not untested behaviour, and deliberately
trying malformed files is the next planned item. Recorded here because a
mutation that survives is a fact about the suite, and leaving it out would
make this section claim more than it has.

## The suite refuses a stale binary

`t/run.sh` does not compile anything: `make test` depends on `terminfo`, so the
normal path rebuilds first. Run directly after an edit, it used to report
six passes for a binary built *before* the edit.

That is not a hypothetical. Three mutations of the number decoder were each
recorded as surviving against a stale binary, and all three are caught
the moment it is rebuilt: a `ti_num` that ignores the width, an `le32` that
reads three bytes, and an `le32` that is unsigned so the sentinels stop
being negative. The suite was testing code that no longer existed.

It now refuses to run when `terminfo.c` is newer than the binary, and exits
non-zero saying so. A suite that cannot tell which code it ran is not a
suite.

## The ncurses extended section, and the offset that is not an offset

After the string table, ncurses appends a section the original `term(5)`
format knows nothing about, relying on other implementations reading only
as far as the header's sizes say. It holds the user-defined capabilities,
`AX`, `XT`, `U8`, `Smulx`, `setrgbf`, and, since nothing else can know them,
their names. 29 of the 44 entries here have one, and `xterm` keeps 89 of its
capabilities in it.

Five 16-bit counts, then the booleans, a pad to an even boundary, the
numbers, then one offset per extended string value followed by one per name,
then the table.

The name offsets are the trap. They are not offsets into the table: they are
offsets from the *end* of the string values, so reading them the obvious way
yields a name sliced out of the middle of some value. Decoding `xterm` that
way reports a boolean capability called `\033[?2004l`. The base is the total
length of the values that are present, and the only reason to believe it is
right is external: the names it produces are exactly the ones `infocmp -x`
prints.

The fourth count is of items actually *stored* in the extended string table,
so an absent value is not one of them. `screen.xterm-256color` is the single
entry here where that shows: 78 extended strings, one of them absent, and
the count says 158 where 159 offsets follow it. A reader that takes it as
the length of the offset array reads the whole array one short out of
position, and that mutation fails on exactly one terminal out of 44.

What the suite checks is not only the values, which are folded into the
boolean, number and string comparisons above, but the *split*: the set of
capabilities this reader found in the extended section must equal
`infocmp -x` minus the predefined names from `term.h`. Not `diff infocmp
infocmp -x`, which looks like the same question and is not, since `infocmp`
hides the obsolete `OT*` capabilities until `-x` is given.

Nothing in this corpus cancels an extended capability, so the `xb@`, `xn@`
and `xs@` paths are written from the format and unproven. The suite says so
on every run rather than passing in silence.

## Parameterised strings, and the one oracle that is not infocmp

A capability like `cup` is not a string, it is a program:
`\E[%i%p1%d;%p2%dH`. Everything above establishes that this reader stores
the program correctly, byte for byte. None of it would notice a reader
that stored the bytes and understood none of them, because `infocmp`
prints the program, not what the program does.

`tput -T TERM cap args` is ncurses running the same program, so that is
the authority for section 06. `terminfo -p FILE ARG...` evaluates every
string capability holding a `%` and prints the result as hex, and 3834
evaluations across 43 terminals agree with `tput` byte for byte: 639
distinct terminal and capability pairs at six parameter tuples each.

The tuples are not arbitrary, and that is the part worth copying. The
conditionals in this corpus compare against the constants 1, 3, 4, 6, 7, 8
and 16, so the first parameter takes the values 0, 1, 7, 8, 16 and 200:
one on each side of every boundary and one exactly on it. With a first
parameter of 1 and 9 only, turning `%<` into `%<=` changes no answer in the
whole corpus, and the mutation survives having broken the decoder.

The count is also not the assertion. A sweep can agree about four thousand
evaluations having exercised three opcodes, so the suite counts which of
the language's operators the compared capabilities actually reach (18 of
them), requires a width or precision somewhere rather than only bare `%d`,
and requires that something branches, which is where the one real bug was.

### What tput found

The branch skipper was wrong. `%{3}` inside a skipped else-branch was
stepped over by one byte too many, so the scan never found the closing
`%;`, and everything after the conditional was dropped. One capability on
one terminal showed it, `xm` on `screen.xterm-256color`, and only for the
parameter tuples that take the then-arm. Nothing in the five sections
above could have seen it: the stored bytes were always right.

`%c` of zero emits 0200, not NUL. ncurses cannot put a NUL in the string
it is building, so it substitutes the high bit, and `tput -T ansi rep 0 0`
starts with the byte 0x80. That is not in terminfo(5); tput is simply what
it is.

### The operators nothing on this machine uses

Nine of them: `%m %& %^ %! %~ %A %O %P %g`. No entry under
`/usr/share/terminfo` reaches any of them, so leaving the matter at a note
would mean nine opcodes written from the document and never run.

Instead `tic` compiles a probe entry that uses them, into `t/tmp`, and
`tput` evaluates it with `$TERMINFO` pointed there. What is written here
is the program, which is the same thing the terminfo source of any real
entry is; the answer still comes from ncurses. tic's own normalisation
shows in the result, since it rewrites `%{70}` as `%'F'`, which is a
reminder that the bytes compared are not the bytes typed.

A check ties the two halves together: every operator the corpus misses
must appear in the probe source, or the suite fails rather than printing a
longer list of unproven things.

### Three classes are not compared, and each one is counted

Printed on every run, so the set that is not compared cannot grow in
silence:

- 7 padded capabilities (`$<5>`). `tput` is `tparm` plus `tputs`, and
  `tputs` is what strips the padding spec and decides from the baud rate
  how many pad characters to emit. Comparing a padded capability would be
  comparing this evaluator against something else.
- 14 with a string-valued parameter (`%s`, `%l`), all of them `Cs` and
  `Ms`. `-p` takes numbers, and these are refused rather than given an
  invented argument.
- 44 termcap-style (`u6`, `u8`), which use `%d` with nothing pushed.
  ncurses has a rule for that. It is not in terminfo(5), and guessing it
  would be writing the oracle's answer down rather than asking for it.

### One mutation survives, and it is equivalent

Stepping over `%'c'` by two bytes instead of four, in the branch skipper.
It lands on the quoted character itself, and `tp_skip` reacts to nothing
but a `%`: if the quoted character is not `%` the scan walks it and the
closing quote and arrives at the same place, and if it is `%` the pair
re-enters the same case and arrives at the same place. The two spellings
cannot differ on any input, so this one is recorded rather than fixed.
The other 23 mutations of the evaluator and 4 of the harness are all
caught. Two of them are worth naming: `%<` as `%<=` fails on 10 of the
3834 comparisons and `%>` as `%>=` on 2, which is the entire return on
choosing the parameter values deliberately.

## What does not work

Every item of `PLAN.md` is ticked, which is not the same as finished. What
is missing now is smaller and more specific than what was missing before.

`%s` and `%l` are refused. Both need a string-valued parameter and `-p`
takes numbers only, so the 14 capabilities that use them here, all `Cs`
and `Ms`, are never evaluated. The refusal is explicit, not a wrong
answer.

The termcap-style capabilities are refused the same way. `u6` and `u8`
use `%d` with nothing pushed; ncurses has a rule for what that pops and
terminfo(5) does not state it, so popping an empty stack is an error here
rather than a guess. 44 of them in this corpus.

There is no `tputs`, so padding is not processed. `-p` emits a `$<5>` as
the five literal bytes it is, which is what `tparm` does and what the
terminfo source says, but nothing external confirms it: the seven padded
capabilities are excluded from the tput comparison precisely because tput
would have stripped them.

`%c` of a value whose low eight bits are zero but which is not itself zero
emits a NUL, because only an exactly-zero value becomes 0200. That is
ncurses' behaviour read from its output, but no parameter tuple here
produces such a value, so it is unproven.

Nothing in this corpus cancels an extended capability, so `xb@`, `xn@` and
`xs@` remain written from the format. The suite says so on every run.

No writing of terminfo files, no terminal setup, no `TERM` resolution
beyond a filename on the command line. `tic` and ncurses exist.

## Malformed files

Item 07, and it found something. The suite truncates a real compiled entry at
every byte through the header and the early sections, then at a stride to the
end, in both modes: 626 runs, no signals, and every refusal carrying a
diagnostic. Its header is sabotaged field by field, wrong magic, counts
larger than the file, negative counts, and each is refused. The extended
header's five counts get the same treatment, and so does an extended name
offset pointing outside its table.

The assertion worth having is not "it does not crash". It is that the first
*accepted* truncation is exactly the end of the sections this parser reads,
computed from the header, not written down: 12-byte header, names,
booleans, pad to even, two bytes per number and per string offset, then the
string table. A truncation before that is a file that must be refused. After
it lies the ncurses extended section, whose absence is not an error: 15 of
the 44 entries here stop at that byte. One number pins both directions.

What it found: **a string offset pointing outside the string table was
accepted in silence.** `ti_str` refused the offset and returned `NULL`,
which is also how it reports a capability that is legitimately absent, so
`dump_strs` skipped it, and a corrupt file was read as valid with the
capability quietly missing. Exit 0, no diagnostic. The comment on that line
already said "malformed file, not an empty capability". It did the other thing.

The offset array is validated at parse time now, as `count_ok` already
does for the counts and for the reason given there, refuse it here,
not at a later read that happens to cope:

```
terminfo: string 0 has offset 30000, outside a 580-byte string table
```

All 44 compiled entries on this machine still parse. Removing the check turns
that assertion red; removing the cursor's bounds check turns two more red.

(Two sentences used to follow this one saying malformed files had never been
tried on purpose and the cursor had never been watched to fail. Item 07 is
what the whole section describes. The paragraph was left behind by the
commit that did the work, and it contradicted the four paragraphs above it.)

## License

GPL-3.0-or-later.
