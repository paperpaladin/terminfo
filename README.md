# terminfo

Reads the **compiled** terminfo binary format. One C11 file, no ncurses and
no libtinfo -- the point of the exercise is to read the bytes.

```
$ ./terminfo -i /usr/share/terminfo/x/xterm
magic 0432
numsize 2
names 48
bools 38
nums 15
strs 413
strtable 1552
name xterm|xterm terminal emulator (X Window System)

$ make test
10 passed, 0 failed
```

## The part a reader cannot get from the file

A compiled terminfo file stores capabilities **positionally**. The name of
the capability at index 0 of the boolean array is not in the file. It is in
a table every reader is expected to already have, in ncurses' order.

So a reader can parse every byte of the format correctly and still be
completely wrong, by holding that table in a different order -- and nothing
about the file will say so. That failure mode is invisible to any test that
only checks the file parsed.

**The tables here were not typed out from a document.** They were derived
from two things on this machine that we do not control:

- `/usr/include/term.h`, which fixes the long name at every index
  (`#define auto_left_margin CUR Booleans[0]`).
- `tic` itself, asked where it puts a given short name: compile a probe
  entry `probe, <name>,` and read back the resulting boolean count, which is
  the index plus one.

`t/derive-caps.py` regenerates exactly what is pasted into `terminfo.c`, so
the tables are reproducible rather than trusted.

## The oracle is ncurses, as a subprocess

`infocmp` is asked what every capability of every terminal on this machine
should be, and the answer is compared value by value:

```
corpus (44 compiled terminal descriptions under /usr/share/terminfo)
legacy format (0432) read: 39 terminals
extended-number format (01036) read: 5 terminals
predefined booleans are infocmp's (294 across 44 terminals)
numbers are infocmp's (202 across all 44 terminals, 5 of them 32-bit)
numbers: 5 values exceed 32767, which a 16-bit decode could not represent
string capabilities are infocmp's, byte for byte (4584 across 44 terminals)
strings: 6 are defined as the EMPTY string, which is not the same as absent
cancelled capabilities are infocmp's (9 across 44 terminals)
cancelled: 9 exist, so -2 is distinguished from -1 on real data
```

Every capability value the harness compares comes from `infocmp`, in both
directions, rather than from a number anybody worked out by hand. The four
floors are the exception and are hand-written on purpose -- at least 30
terminals, 200 booleans, 100 numbers, 4000 strings -- and they exist so that
a corpus too thin to prove anything cannot pass. They are reported as a thin
corpus rather than as a disagreement, because the combined form used to print
"booleans: 0 terminals disagree with infocmp, 191 compared" as a failure.

(This paragraph used to say nothing in the harness compares against a
hand-worked number, which the floors contradict.)

## Both number widths, and the value that proves it

Magic 0432 stores numeric capabilities as signed 16-bit integers; magic
01036 stores them as signed 32-bit integers and is otherwise identical. The
width comes from the header's magic rather than from guessing at the
section size.

The assertion that matters is not that the wide values agree -- it is that
**some value could not have been read any other way**:

```
numbers: 5 values exceed 32767, which a 16-bit decode could not represent
string capabilities are infocmp's, byte for byte (4584 across 44 terminals)
strings: 6 are defined as the EMPTY string, which is not the same as absent
cancelled capabilities are infocmp's (9 across 44 terminals)
cancelled: 9 exist, so -2 is distinguished from -1 on real data
```

`pairs#65536` on a 256-colour terminal is the usual one. Without that
check, a reader that quietly fell back to 16 bits would still agree with
`infocmp` on every number small enough to fit, which is almost all of them.

This replaced the weakest assertion the harness had: it used to skip every
magic 01036 file and assert that the skip count was exactly 5, which is a
hardcoded fact about *this machine* and true nowhere else. Reading them
deleted the assertion rather than making it more precise.

## Two sentinels, not one

ncurses stores two different absent-markers in the number array: `-1` for
ABSENT and `-2` for CANCELLED. A reader that folds them together parses the
file correctly and loses a distinction `infocmp` prints, so they are kept
apart.

## Padding is a one-byte bug that still parses

Between sections the file is padded to an even byte boundary. Getting it
wrong shifts every number, every string offset and the whole extended
section by exactly one byte -- and the result is still a file that parses,
with plausible-looking wrong values. That is why it has its own deliberate
sabotage in the harness rather than being left to the value comparison.

## Strings are compared as bytes, not as notation

4584 string capabilities across 44 terminals, byte for byte against
`infocmp`. The comparison is in **hex**, and that is the decision worth
explaining.

A string capability is arbitrary bytes, and terminfo's source notation has
several spellings for the same byte -- `\E`, `\e` and `\033` are all ESC.
Printing that notation from the reader under test and diffing the text would
compare `infocmp` against an imitation of itself, and would pass or fail on
spelling rather than on bytes. So `terminfo -d` emits hex, and
`t/caps-hex.py` decodes `infocmp`'s notation with a decoder that shares
nothing with the reader: one parses escape sequences out of text, the other
walks an offset table in a binary file. A bug common to both is not a bug
either could hide.

Three things the comparison turned up, none of which was a bug in the
reader:

**`acsc` is the one capability `infocmp` does not print as stored.** It is a
sequence of (from, to) byte pairs, and `infocmp` *sorts* them. Three
terminals here -- `hurd` and two `rxvt-unicode` variants -- store them in an
order it does not reproduce, with the identical multiset of pairs. Both
sides are normalised through one function, so the comparison is between the
set of pairs, which is what `acsc` means; comparing the order would assert
something `term(5)` does not promise.

**A capability can be defined as the empty string**, which is not the same
as being absent. `Eterm` defines `smkx` and `rmkx` that way. The first
version of the comparison used `split()`, which collapses an empty field, and
the two sides then disagreed about a capability both had read correctly. Six
of them exist and the count is asserted.

**Cancellation needed its own section, and a mutation found out why.**
Making the reader treat `-2` (cancelled) as `-1` (absent) **survived** the
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

They are untested machinery rather than untested behaviour, and deliberately
trying malformed files is the next planned item. Recorded here because a
mutation that survives is a fact about the suite, and leaving it out would
make this section claim more than it has.

## The suite refuses a stale binary

`t/run.sh` does not compile anything -- `make test` depends on `terminfo`, so the
normal path rebuilds first. Run directly after an edit, it used to report
six passes for a binary built *before* the edit.

That is not a hypothetical. Three mutations of the number decoder were each
recorded as **surviving** against a stale binary, and all three are caught
the moment it is rebuilt: a `ti_num` that ignores the width, an `le32` that
reads three bytes, and an `le32` that is unsigned so the sentinels stop
being negative. The suite was testing code that no longer existed.

It now refuses to run when `terminfo.c` is newer than the binary, and exits
non-zero saying so. A suite that cannot tell which code it ran is not a
suite.

## What does not work

**The ncurses extended-capability section is not read.** It is where
user-defined capabilities such as `Smulx` and `setrgbf` live, and where
`term(5)` stops documenting. `xterm` here has 183 predefined string
capabilities and `infocmp -x` reports 269, so roughly a third of what the
file holds is still unread -- which is why the string comparison runs
`infocmp` *without* `-x`: asking for extended capabilities would report 86
absences per terminal that are not defects.

**Parameterised strings are not evaluated.** A capability like `cup` is a
small stack program; `tput cup 3 4` is the external authority for what it
evaluates to, and nothing here calls it yet. The harness's own header
mentions `tic` and `tput` as oracles, which is ahead of what it currently
does -- items 06 and 07 of `PLAN.md` are what make that true.

**Malformed files have never been tried on purpose.** The cursor bounds-checks
every read and its error flag is sticky, and that code has never been watched
to fail. Until item 07 it is untested machinery.

No writing of terminfo files, no terminal setup, no `TERM` resolution, no
`tputs`. `tic` and ncurses exist.

## License

GPL-3.0-or-later.
