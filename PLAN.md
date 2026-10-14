# terminfo: plan

## Contract

`terminfo` reads the compiled terminfo binary format and reports what is
in it. One C11 file, no ncurses and no libtinfo: the point of the exercise is
to read the bytes.

```
terminfo -i FILE      header facts: magic, section sizes, number width
terminfo -d FILE      dump every capability, name and value
```

Exit status: 0 the file was read, 1 the file is malformed, 2 usage error.

Two on-disk formats, which differ in one field and nothing else. The legacy
one (magic 0432, `term(5)`) stores numeric capabilities as signed 16-bit
integers; the extended-number format (magic 01036, ncurses 6.1 and later)
stores them as signed 32-bit integers.

## Hard invariant

Every capability we report for a terminal is the one `infocmp` reports.

Not "a plausible value", not "the value `term.h` suggests should be at that
index": the value ncurses itself prints for that terminal, compared across
every compiled description on the machine.

A compiled file stores capabilities positionally. The name of the
capability at index `i` lives in a table every reader is
expected to already have. So a reader can parse every byte correctly and
still be completely wrong, by holding the table in a different order. That
failure mode is invisible to any test that only checks the file was parsed.

The second half: **a file claiming more than `term(5)` allows is malformed,
not large.** Every offset and count after the twelve-byte header comes out
of the file, so every read goes through a cursor that knows the file's
length, and the cursor's error flag is sticky.

## Oracle

Ranked by how little of it we control.

1. `infocmp`, for what every capability of every terminal on this
   machine should be. 44 compiled descriptions under `/usr/share/terminfo`,
   including 5 in the extended-number format. This is the oracle.
2. `tic`, asked where it puts a capability. The capability-name tables
   were not typed out from a document: `t/derive-caps.py` compiles a probe
   entry naming one capability and reads back the resulting count, which is
   the index plus one. It regenerates exactly what is pasted into
   `terminfo.c`, so the tables can be re-derived, not trusted.
3. `/usr/include/term.h`, which fixes the long name at every index
   (`#define auto_left_margin CUR Booleans[0]`). A second, independent
   source for the same ordering.
4. `tput`, for what a parameterised string evaluates to. This is the one
   question infocmp cannot answer: it says what the program IS, byte for
   byte, and a reader that stored the bytes and understood none of them
   would satisfy it. 3834 evaluations across 43 terminals and six
   parameter tuples, plus 32 on an entry `tic` compiles from a probe
   source so that the nine operators no real entry here uses are run as
   well.

`/usr/share/terminfo` is treated as strictly read-only, and everything the
harness builds goes under `t/tmp/` inside this repo, not a shared
`/tmp` path.

## Non-goals

Writing terminfo files. `tic` exists.

Being ncurses. No `tputs`, no terminal setup, no `TERM` resolution beyond
reading a file named on the command line.

The source (text) terminfo format. This reads compiled files; `tic` is the
thing that compiles.

Capabilities we cannot check. If `infocmp` will not tell us what a value
should be, it does not get reported as if we knew.

## Commit sequence

- [x] 00 header, magic and section layout, with `-i`
      why: every offset and count in the file comes from the header, so
           nothing can be read until the header is trusted, and a cursor
           that knows the file length has to exist before the first read.
      done: both magics, the even-byte padding between sections, and the
            `term(5)` section limits enforced as "malformed, not large".
      note: the padding has its own sabotage in the harness, because
            getting it wrong shifts every number, every string offset and
            the whole extended section by exactly one byte, which still
            parses.
- [x] 01 booleans, and the capability-name tables derived from `tic`
      why: the tables are the part a reader cannot get from the file, so
           they are the part most likely to be silently wrong. Deriving
           them from `tic` and `term.h` instead of typing them is the
           whole point.
      proves: 294 boolean values across 44 terminals are `infocmp`'s.
      note: indices at and past 37 are ncurses' obsolete capabilities,
            named `OT`-something. `tic` does write them, xterm here has
            38 booleans, so `OTbs` is in the file, and a reader that
            stops at the "standard" count gets the array length wrong.
- [x] 02 numbers, 16-bit, with -1 and -2 kept apart
      why: ncurses stores two different sentinels in the number array,
           ABSENT (-1) and CANCELLED (-2), and a reader that folds them
           together loses the distinction `infocmp` prints.
      proves: 177 numeric values across the 39 legacy-format terminals are
            `infocmp`'s, and the 5 extended-number terminals are skipped
            deliberately instead of reading wrongly.
- [x] 03 32-bit numbers, so the 5 skipped terminals stop being skipped
      why: the suite asserted that exactly 5 terminals were skipped, which
           is a hardcoded fact about this machine and the weakest thing in
           the harness. Reading them removes the assertion,
           not making it more precise.
      done: le32 beside le16, with the width taken from the header's
      magic, not guessed from the section size. The cast goes
            through int32_t instead of shifting into a signed int, because
            p[3] << 24 with the top bit set is undefined when int is 32
            bits: the one place where the obvious spelling is wrong.
      proves: 202 numbers across all 44 terminals, up from 177 across 39.
            And the assertion that actually matters is not that the wide
            values agree but that FIVE OF THEM EXCEED 32767, which a 16-bit
            decode could not represent at all. Without that, a reader
            quietly falling back to 16 bits would still agree with infocmp
            on every number small enough to fit, which is almost all of
            them. pairs#65536 on a 256-colour terminal is the usual one.
      found: THE SUITE WAS TESTING A STALE BINARY. t/run.sh compiles
            nothing, and run directly after an edit it reported six passes
            for a binary built before the edit. Three mutations of the
            number decoder were each recorded as SURVIVING, and all three
            are caught the moment it is rebuilt: a ti_num ignoring the
            width, an le32 reading three bytes, and an unsigned le32 whose
            sentinels stop being negative. It now refuses to run when
            terminfo.c is newer than the binary and exits non-zero saying
            so. A suite that cannot tell which code it ran is not a suite.
- [x] 04 the string table and the offset array
      why: the largest section and the one with the most ways to be subtly
           wrong: the values are offsets into a separate table, -1 means
           absent, -2 means cancelled, and an offset past the table end is
           malformed, not empty.
      done: ti_str returns three outcomes through one return: NULL for
            absent or malformed, a sentinel address for cancelled, and the
            bytes otherwise. The length comes from a memchr bounded by the
            table, not from strlen, so an unterminated string at the
            table's end cannot be read off the end.
      proves: 4584 string capabilities across 44 terminals, byte for byte
            against infocmp. Compared as HEX: a string capability is
            arbitrary bytes and terminfo's notation has several spellings
            per byte, so diffing the notation would compare infocmp against
            an imitation of itself and would pass or fail on spelling.
            t/caps-hex.py decodes infocmp's notation with a decoder sharing
            nothing with the reader: one parses escapes out of text, the
            other walks an offset table in a binary file.
      found: acsc is the one capability infocmp does NOT print as stored.
            It is a sequence of (from, to) byte pairs and infocmp sorts
            them; hurd and two rxvt-unicode variants store them in an order
            it does not reproduce, with the identical multiset of pairs.
            Both sides are normalised through one function so the
            comparison is between the set of pairs, the thing acsc
            means. Comparing the order would assert something term(5) does
            not promise.
      found: a capability can be defined as the EMPTY string, and that is not
            the same as absent, Eterm defines smkx and rmkx that way. The
            first comparison used split(), which collapses an empty field,
            and the two sides then disagreed about a capability both had
            read correctly. Six exist and the count is asserted.
      found: CANCELLATION NEEDED ITS OWN SECTION, and a mutation found out
            why. Treating -2 as -1 SURVIVED the string comparison, because
            a cancelled capability emits `s@` and the comparison only
            looked at `s ` lines. Nine cancelled capabilities exist here
            across all three classes, infocmp prints them all as `name@`,
            and they are now compared as one set.
      survived: two mutants, both malformed-file cases, and no file in this
            corpus is malformed: an offset exactly equal to the table
            size accepted, not refused, and strlen instead of a
            bounded memchr. Untested machinery, not untested
            behaviour; item 07 is deliberately trying malformed files.
- [x] 05 the ncurses extended-capability section
      why: it is where user-defined capabilities such as `Smulx` and
           `setrgbf` live, it is the part `term(5)` does not document, and
           `infocmp -x` is the oracle that knows what is in it.
      files: terminfo.c (ti_parse_ext, etab_at, ext_name, dump_ext),
            t/run.sh (the three comparisons switched to infocmp -x, a
            section for the predefined/extended split, six more malformed
            cases), README.md.
      proves: 734 extended capabilities across 29 of the 44 terminals are
            exactly the set `infocmp -x` reports and `term.h` does not
            define, and their values are compared with everything else:
            booleans 294 -> 344, numbers 202 -> 211, strings 4584 -> 5259.
            The header's extended counts are non-empty for exactly the 29
            terminals the oracle adds capabilities to, so a reader that
            located the section one byte out could not agree with it about
            the 15 entries that have none.
      done: the trap is the NAME offsets. They are measured from the end of
            the extended string values, not from the start of the table, so
            the obvious reading returns a name cut out of the middle of a
            value: xterm decoded that way has a boolean called
            `\033[?2004l`. The base is the summed length of the values that
            are present, and nothing in the file states it.
      found: the fourth extended count is of items STORED, so an absent
            value is not counted, and the offset array is longer than it by
            one. screen.xterm-256color is the only entry on this machine
            where the two differ (158 against 159), and a reader trusting
            that count reads the whole array one short out of position.
      found: THE BOOLEAN COMPARISON WAS COVERING FOR ITSELF. Its missing
            direction was filtered through the list of predefined BOOLEAN
            names, ostensibly so the unread extended capabilities were not
            demanded of it. That filter was also swallowing cancelled
            NUMBERS and STRINGS, which infocmp spells `name@` with no class
            attached, and which `want` therefore carried. Deleting the
            filter (item 05 removed its reason to exist) turned Eterm red on
            `ncv@` and `kNXT@`. Cancellation now belongs to the
            kind-agnostic section alone, on both sides.
      found: the README claimed malformed files had never been tried on
            purpose, in the paragraph after four describing item 07 doing
            exactly that, and counted 41 compiled entries where there are
            44.
      mutations: seven planted, all seven caught. Name offsets read as table
            offsets; the offset array length taken from the header's item
            count; the even-byte pad dropped before the extended header and
            again between the extended booleans and numbers; extended
            booleans not reported; the base off by one per value; an absent
            value counted into the base. The two that touch
            screen.xterm-256color alone fail one terminal out of 44, which
            is what the dedicated extended section is for.
      skip: no entry under /usr/share/terminfo cancels an extended
            capability, so the xb@/xn@/xs@ paths are written from the format
            and unproven. The suite prints that on every run.
- [x] 06 parameterised strings evaluated against `tput`
      why: a string capability such as `cup` is a tiny stack program, and
           `tput cup 3 4` is an external authority for what it evaluates
           to. This is the only item here whose oracle is not `infocmp`.
      files: terminfo.c (tp_skip, tparm_eval, dump_param, the -p mode),
            t/run.sh (section 06 and the tic-compiled probe), Makefile,
            README.md.
      done: an evaluator for the whole of terminfo(5)'s stack language in
            one function, plus `terminfo -p FILE ARG...`, which evaluates
            every string capability holding a % and prints the result as
            hex. It does NOT decide which of its answers are worth
            checking: t/run.sh picks the comparable set out of infocmp's
            own text, because a filter living in the code under test would
            be the code choosing its own examination.
      proves: 3834 evaluations across 43 terminals agree with `tput` byte
            for byte, 639 distinct terminal/capability pairs at six
            parameter tuples each, and 18 of the language's operators are
            reached. Not the count that matters on its own: the suite also
            asserts WHICH operators the compared set reaches, because a
            sweep can agree about four thousand evaluations having run
            three opcodes.
      done: the six tuples are not arbitrary. The conditionals in this
            corpus compare against 1, 3, 4, 6, 7, 8 and 16, so the first
            parameter takes the values 0, 1, 7, 8, 16 and 200: one on each
            side of every boundary and one ON it. With 1 and 9 only,
            turning `%<` into `%<=` changes no answer anywhere in the
            corpus and the mutation survives having broken the decoder.
      found: TPUT FOUND A REAL BUG, in the branch skipper. `%{3}` inside a
            skipped else-branch was stepped over by one byte too many, so
            the scan never found the closing `%;` and everything after the
            conditional was swallowed. One capability on one terminal
            showed it, `xm` on screen.xterm-256color, and only for the
            parameter tuples that take the then-arm.
      found: `%c` of zero emits 0200, not NUL. ncurses cannot put a NUL in
            the string it is building, so it substitutes the high bit, and
            `tput -T ansi rep 0 0` starts with the byte 0x80.
      note: three classes are excluded from the comparison and each one is
            counted and printed on every run, so the set that is not
            compared cannot grow in silence. 7 padded capabilities ($<>),
            because tput is tparm plus tputs and tputs is what strips the
            padding spec; 14 with a string-valued parameter (%s, %l),
            which this evaluator refuses rather than inventing an argument
            for; and 44 termcap-style (u6, u8), which use %d with nothing
            pushed, a rule ncurses has and terminfo(5) does not state.
      done: nine operators (%m %& %^ %! %~ %A %O %P %g) are reached by no
            entry on this machine. Rather than leave them written from the
            document, `tic` compiles a probe entry that uses them into
            t/tmp and `tput` evaluates it with $TERMINFO pointed there. The
            program is ours, like any terminfo source; the answer is still
            ncurses'. A check ties the two together: every operator the
            corpus misses must appear in the probe source, or the suite
            fails rather than printing a longer list of unproven things.
      mutations: 28 planted, 27 caught. 24 in the evaluator: %c of zero;
            the %{n} skip bug itself; %i incrementing one parameter; %t
            taking the wrong arm; %- reversed; %< as <=; %> as >=; %pN
            always pushing p1; %{n} pushing zero; width dropped from the
            conversion; the extended strings not evaluated; the last
            output byte dropped; %A as %&; %O as %|; %! as %~; %~ as %!;
            %& as %|; %^ as %&; %m as %/; %P discarding its value; %g
            reading the dynamic variables for a static one; the %/ zero
            guard removed; and the `:` flag introducer ignored. The %<
            and %> pair fail on 10 and 2 terminal/tuple pairs out of 3834,
            which is what the boundary values in the tuples buy.
            4 in the harness: an empty operator census, a dropped
            parameter tuple, the comparison reading its own answer back as
            the oracle's, and an operator removed from the probe source
            while the corpus still does not reach it.
      survived: one, and it is equivalent. In the branch skipper, stepping
            over `%'c'` by two bytes instead of four lands on the quoted
            character itself, and tp_skip reacts to nothing but a `%`: if
            the quoted character is not `%` the scan walks it and the
            closing quote and arrives at the same place, and if it IS `%`
            the pair re-enters the same case and arrives at the same
            place. The two spellings cannot differ on any input.
- [x] 07 malformed files on purpose
      why: the cursor's bounds checking has never been watched to fail.
           Truncate at each section boundary, claim a section larger than
           the file, point an offset past the string table, and assert a
           diagnostic, not a crash or a plausible answer.

## Open questions

- Whether to read `$TERMINFO`-style directory hierarchies, or stay a
  file-at-a-time reader. The second is a smaller contract and the harness
  does the walking already.
- Whether `%s` and `%l` are worth supporting. They need a string-valued
  parameter, `-p` takes numbers only, and the 14 capabilities that use them
  here are all `Cs` and `Ms`. Supporting them means deciding how a string
  argument reaches the command line, which is a CLI question rather than a
  decoding one.
- RESOLVED by item 03: the "5 terminals skipped" assertion is gone, and
  what replaced it is portable, "some number exceeds 32767" is true of any
  corpus containing a 256-colour terminal, and false of one that does not,
  which is the right way round for an assertion about this decoder.
