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
6 passed, 0 failed
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
16-bit numbers are infocmp's (177 across 39 terminals)
```

Nothing in the harness compares output against a number anybody writing the
harness worked out by hand.

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

## What does not work

**Strings are not read yet.** The header's string-table size is validated,
and the offset array and the table itself are not parsed, so `-d` dumps
booleans and numbers only. That is most of a terminfo file by volume and all
of the interesting parts: `cup`, `smcup`, `setaf`.

**32-bit numbers are not read.** The 5 extended-number-format terminals in
the corpus are deliberately skipped rather than read wrongly -- and the
suite asserts the count is exactly 5, which is a hardcoded fact about *this
machine* and the weakest assertion in the harness. Reading them is the next
planned item, and it deletes the assertion rather than refining it.

**The ncurses extended-capability section is not read.** It is where
user-defined capabilities such as `Smulx` and `setrgbf` live, and where
`term(5)` stops documenting.

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
