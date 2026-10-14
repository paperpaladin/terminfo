#!/bin/sh
# terminfo test suite.
#
# The oracle is ncurses, invoked as a subprocess: `infocmp` for what every
# capability of every terminal on this machine should be, compared in both
# directions. Capability values are never compared against a number anybody
# writing this harness worked out by hand; the four size floors are, and they
# are there so a corpus too thin to prove anything cannot pass.
#
# This header used to claim three authorities -- adding `tic` for the source
# round-trip and `tput` for what a parameterised string evaluates to. Neither
# binary is ever invoked here: they are only checked for existence at the top,
# so a machine with infocmp and no tput got `exit 1` for a tool the suite does
# not use. `tic` does feed t/derive-caps.py, which re-derives the capability
# name tables, but `make test` does not run it. `tput` is PLAN item 06,
# unticked, and the README says so.
#
# /usr/share/terminfo is treated as strictly read-only. Everything is built
# under t/tmp/, inside this repo: other agents run concurrently on this
# machine and a shared /tmp path has corrupted work before.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
TERMINFO_BIN=${TERMINFO_BIN:-$root/terminfo}
TIDIR=${TIDIR:-/usr/share/terminfo}
work=$root/t/tmp/run
rm -rf "$work"
mkdir -p "$work"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$*"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$*"; }

[ -x "$TERMINFO_BIN" ] || { echo "no terminfo binary at $TERMINFO_BIN (run make)"; exit 1; }

# Refuse a binary older than the source it is supposed to be testing.
#
# This script does not compile anything -- `make test` depends on `all`, so
# the normal path is fine -- but run directly after an edit it happily
# reported six passes for a binary built before the edit. That is not a
# hypothetical: three mutations of the number decoder were each recorded as
# SURVIVING against a stale binary, and all three are caught the moment it
# is rebuilt. A suite that cannot tell which code it ran is not a suite.
#
# shortcut: -nt is not in POSIX test, it is a widely implemented extension;
# dash and bash both have it, which covers every /bin/sh this will meet.
if [ "$root/terminfo.c" -nt "$TERMINFO_BIN" ]; then
	echo "terminfo.c is newer than $TERMINFO_BIN -- run make." >&2
	echo "Refusing to report results for a binary that is not the source." >&2
	exit 1
fi
command -v infocmp >/dev/null || { echo "infocmp not found; no oracle"; exit 1; }
# tic is needed by t/derive-caps.py, which `make test` does not run, so its
# absence is noted rather than fatal. tput is not used at all yet (PLAN item
# 06); requiring it meant a machine with infocmp and no tput ran nothing.
command -v tic  >/dev/null || echo "note: tic absent; t/derive-caps.py cannot re-derive the name tables"
command -v tput >/dev/null || echo "note: tput absent; not used by this suite yet (PLAN item 06)"
[ -d "$TIDIR" ]  || { echo "no terminfo corpus at $TIDIR"; exit 1; }

# ---------------------------------------------------------------- the corpus
# Follow symlinks: several entries on this machine are links, and infocmp
# resolves them by name, so they are distinct terminals as far as the oracle
# is concerned.
corpus=$(find "$TIDIR" -mindepth 2 \( -type f -o -type l \) | sort)
nterm=$(printf '%s\n' "$corpus" | grep -c .)
if [ "$nterm" -lt 30 ]; then
	bad "corpus too small: $nterm terminals under $TIDIR"
else
	ok "corpus ($nterm compiled terminal descriptions under $TIDIR)"
fi

# Both magics must be represented, or the 32-bit number path is untested and
# the suite cannot tell.
nleg=0
n32=0
for f in $corpus; do
	m=$("$TERMINFO_BIN" -i "$f" | sed -n 's/^magic //p')
	case $m in
	0432)  nleg=$((nleg+1)) ;;
	01036) n32=$((n32+1)) ;;
	*)     bad "unexpected magic $m for $f" ;;
	esac
done
[ "$nleg" -gt 0 ] && ok "legacy format (0432) read: $nleg terminals" \
	|| bad "no legacy-format terminal in the corpus"
[ "$n32" -gt 0 ] && ok "extended-number format (01036) read: $n32 terminals" \
	|| bad "no 32-bit-number terminal in the corpus"

# ------------------------------------------------- booleans against infocmp
# `infocmp -x -1` prints one capability per line; a bare name is a boolean
# that is present. `name@` is a capability cancelled in the source, and
# infocmp spells that the same way whether the capability is a boolean, a
# number or a string, so neither side of this comparison carries a
# cancellation: they are compared as one kind-agnostic set further down.
#
# Both sides were cancellation-blind by accident until item 05. `want` took
# the `name@` lines and `got` took our `b@` ones, and the missing direction
# was then filtered through the list of predefined BOOLEAN names, which
# silently dropped the cancelled numbers and strings infocmp had put in
# `want`. Deleting the filter (the extended section is read now, so it had
# no reason left to exist) made Eterm fail on `ncv@` and `kNXT@`: a cancelled
# number and a cancelled string, demanded of the boolean set. The filter had
# been covering for that since the booleans were written.
#
# Both sides are now the whole of `infocmp -x`, including the extended
# booleans AX, XT and U8.
# The predefined capability names, from /usr/include/term.h, via the same
# parser t/derive-caps.py uses. These are what separates a capability this
# reader is supposed to know from an ncurses *extended* one (PLAN item 05,
# unticked) -- infocmp -x reports both, and only the first kind is a bug when
# missing. Taking the list from term.h rather than from terminfo.c keeps the
# comparison independent of the code under test.
# derive-caps.py emits the C tables it derives from `tic` probes plus
# term.h; its stdout carries the SHORT names, which is what infocmp prints.
# term_h_longnames() alone is the wrong source here -- it gives
# backspaces_with_bs where infocmp says OTbs, so filtering on it removed
# every name and made the check vacuous again. Found that by re-running the
# mutation this check exists for and watching it still pass.
python3 "$root/t/derive-caps.py" 2>/dev/null > "$work/caps.c" \
	|| bad "derive-caps.py failed, so predefined names are unknown"
sed -n '/bool_names\[/,/};/p' "$work/caps.c" \
	| grep -o '"[^"]*"' | tr -d '"' | sort > "$work/predef_b"
sed -n '/num_names\[/,/};/p' "$work/caps.c" \
	| grep -o '"[^"]*"' | tr -d '"' | sort > "$work/predef_n"
sed -n '/str_names\[/,/};/p' "$work/caps.c" \
	| grep -o '"[^"]*"' | tr -d '"' | sort > "$work/predef_s"
# All three classes in one set. This is what separates a PREDEFINED
# capability from an ncurses extended one, and the extended section below
# needs the distinction without caring which class a name belongs to.
sort -u "$work/predef_b" "$work/predef_n" "$work/predef_s" > "$work/predef"
[ "$(grep -c . < "$work/predef_b")" -eq 44 ] || bad "term.h gave $(grep -c . < "$work/predef_b") boolean names, expected 44"

nbool=0
nbad=0
for f in $corpus; do
	t=${f##*/}
	infocmp -x -1 "$t" 2>/dev/null 		| sed -n 's/^	\([a-zA-Z0-9_]*\),$/\1/p' 		| sort > "$work/want"
	"$TERMINFO_BIN" -d "$f" 		| sed -n 's/^b \(.*\)$/\1/p;s/^xb \(.*\)$/\1/p' 		| sort > "$work/got"
	# Both directions. `comm -13` alone reports only what WE have and
	# infocmp does not -- so a decoder that stopped early and simply failed
	# to report capabilities passed. Truncating dump_bools to the first 37
	# took the count from 294 to 257 and left the suite green, which is
	# exactly the failure mode PLAN.md:93 names ("a reader that stops at
	# the 'standard' count gets the array length wrong"). The strings and
	# cancelled sections were already two-way; these two were not.
	#
	#
	# The missing-from-ours direction used to be filtered down to
	# predefined names, because the extended section was unread and every
	# AX that infocmp reported was a documented gap rather than a defect.
	# Item 05 closed the gap, so the filter went with it: an extended
	# boolean infocmp reports and this reader does not is now a failure
	# like any other.
	extra=$(comm -13 "$work/want" "$work/got")
	missing=$(comm -23 "$work/want" "$work/got")
	if [ -z "$extra" ] && [ -z "$missing" ]; then
		nbool=$((nbool + $(grep -c . < "$work/got")))
	else
		nbad=$((nbad+1))
		if [ "$nbad" -le 3 ]; then
			[ -n "$extra" ] && printf '  %s: we report, infocmp does not: %s\n' \
				"$t" "$(printf '%s' "$extra" | tr '\n' ' ')"
			[ -n "$missing" ] && printf '  %s: infocmp reports, we do not: %s\n' \
				"$t" "$(printf '%s' "$missing" | tr '\n' ' ')"
		fi
	fi
done
if [ "$nbad" -ne 0 ]; then
	bad "booleans: $nbad terminals disagree with infocmp, $nbool compared"
elif [ "$nbool" -le 200 ]; then
	# A thin corpus is not a disagreement. Reported separately because the
	# combined form printed "booleans: 0 terminals disagree with infocmp, N
	# compared" as a FAILURE -- blaming infocmp for a corpus that was
	# simply too small to prove anything.
	bad "booleans: only $nbool compared across $nterm terminals, under the 200 floor"
else
	ok "booleans are infocmp's, extended ones included ($nbool across $nterm terminals)"
fi

# -------------------------------------------------- numbers against infocmp
# `name#value`, across BOTH formats. This used to skip every magic 01036
# file and assert the skip count was exactly 5 -- a hardcoded fact about
# this machine, and the weakest assertion in this harness. Reading the
# 32-bit numbers deletes it rather than making it more precise.
nnum=0
nbad=0
nwide=0
nbig=0
for f in $corpus; do
	t=${f##*/}
	[ "$("$TERMINFO_BIN" -i "$f" | sed -n 's/^numsize //p')" = 4 ] &&
		nwide=$((nwide+1))
	# infocmp renders any value above 255 in hex (colors#0x100), so the
	# oracle's text is normalised to decimal before comparing. Comparing
	# the rendering instead of the value would be comparing infocmp to
	# itself.
	infocmp -x -1 "$t" 2>/dev/null \
		| sed -n 's/^	\([a-zA-Z0-9_]*\)#\(.*\),$/\1 \2/p' \
		| while read -r nm v; do printf '%s %d\n' "$nm" "$((v))"; done \
		| sort > "$work/want"
	"$TERMINFO_BIN" -d "$f" | sed -n 's/^n //p;s/^xn //p' | sort > "$work/got"
	# Values above 32767 cannot be read at all by a 16-bit decode, so
	# they are counted separately: they are the ones that prove the
	# extended format is being read rather than merely accepted.
	nbig=$((nbig + $(awk '$2 > 32767' < "$work/got" | grep -c . || true)))
	# Both directions, as with the booleans above: `comm -13` alone could
	# not see a number we failed to report, and truncating dump_nums to the
	# first 20 took the count from 202 to 198 with the suite still green.
	# No predefined-only filter on the missing side any more; see the
	# booleans above.
	extra=$(comm -13 "$work/want" "$work/got")
	missing=$(comm -23 "$work/want" "$work/got")
	if [ -z "$extra" ] && [ -z "$missing" ]; then
		nnum=$((nnum + $(grep -c . < "$work/got")))
	else
		nbad=$((nbad+1))
		if [ "$nbad" -le 3 ]; then
			[ -n "$extra" ] && printf '  %s: we report, infocmp does not: %s\n' \
				"$t" "$(printf '%s' "$extra" | tr '\n' ' ')"
			[ -n "$missing" ] && printf '  %s: infocmp reports, we do not: %s\n' \
				"$t" "$(printf '%s' "$missing" | tr '\n' ' ')"
		fi
	fi
done
if [ "$nbad" -ne 0 ]; then
	bad "numbers: $nbad terminals disagree with infocmp, $nnum compared"
elif [ "$nnum" -le 100 ]; then
	# A thin corpus is not a disagreement. Reported separately because the
	# combined form printed "numbers: 0 terminals disagree with infocmp, N
	# compared" as a FAILURE -- blaming infocmp for a corpus that was
	# simply too small to prove anything.
	bad "numbers: only $nnum compared across $nterm terminals, under the 100 floor"
else
	ok "numbers are infocmp's ($nnum across all $nterm terminals, $nwide of them 32-bit)"
fi
# A 16-bit read cannot produce these at all, so this is the assertion that
# the wide decode is doing something rather than being skipped quietly.
# `pairs#65536` on a 256-colour terminal is the usual one.
[ "$nbig" -gt 0 ] \
	&& ok "numbers: $nbig values exceed 32767, which a 16-bit decode could not represent" \
	|| bad "no number above 32767 was read, so the 32-bit decode is untested"

# -------------------------------------------------- strings against infocmp
# The largest section of a terminfo file and the one with the most ways to
# be subtly wrong: the values are OFFSETS into a separate table, -1 means
# absent, -2 means cancelled, and an offset past the table end is a
# malformed file rather than an empty capability.
#
# Compared as HEX BYTES, not in terminfo's notation. A string capability is
# arbitrary bytes and the source notation has several spellings per byte
# (\E, \e and \033 are all ESC), so diffing the notation would compare
# infocmp against an imitation of itself and would pass or fail on
# spelling. t/caps-hex.py decodes infocmp's notation with a decoder that
# shares nothing with the reader under test -- one parses escapes out of
# text, the other walks an offset table in a binary file.
#
# -x on both sides. This used to be plain `infocmp`, because asking for the
# extended capabilities would have reported 86 absences per terminal that
# were not defects. Item 05 reads them, so they are compared here with
# everything else: an extended string is bytes in a table like any other.
nstr=0
nbad=0
nempty=0
for f in $corpus; do
	t=${f##*/}
	"$TERMINFO_BIN" -d "$f" | sed -n 's/^s //p;s/^xs //p' \
		| python3 "$here/caps-hex.py" --normalize | sort > "$work/sgot"
	# Drop the cancelled entries: caps-hex.py emits those as `name @` for
	# the section below, and they are not string VALUES. Comparing them
	# here would report every cancelled capability as a missing string.
	infocmp -x -1 "$t" 2>/dev/null \
		| python3 "$here/caps-hex.py" | awk '$2!="@"' | sort > "$work/swant"
	nstr=$((nstr + $(grep -c . < "$work/sgot")))
	# A capability defined as the EMPTY string is not an absent one, and
	# Eterm defines smkx and rmkx that way. Counted so that the
	# distinction is a number in the output rather than a silence.
	nempty=$((nempty + $(awk 'NF==1' < "$work/sgot" | grep -c . || true)))
	if [ -n "$(comm -3 "$work/sgot" "$work/swant")" ]; then
		nbad=$((nbad+1))
		[ "$nbad" -le 3 ] && comm -3 "$work/sgot" "$work/swant" | head -6
	fi
done
if [ "$nbad" -ne 0 ]; then
	bad "strings: $nbad terminals disagree with infocmp, $nstr compared"
elif [ "$nstr" -le 4000 ]; then
	# A thin corpus is not a disagreement. Reported separately because the
	# combined form printed "strings: 0 terminals disagree with infocmp, N
	# compared" as a FAILURE -- blaming infocmp for a corpus that was
	# simply too small to prove anything.
	bad "strings: only $nstr compared across $nterm terminals, under the 4000 floor"
else
	ok "string capabilities are infocmp's, byte for byte ($nstr across $nterm terminals)"
fi
[ "$nempty" -gt 0 ] \
	&& ok "strings: $nempty are defined as the EMPTY string, which is not the same as absent" \
	|| bad "no empty-valued string capability was read, so that case is untested"

# ----------------------------------------------- cancelled, across all three
# A CANCELLED capability is the database saying "this one does not apply",
# which is not the same as saying nothing about it. ncurses stores -2 where
# -1 means absent, for booleans, numbers and strings alike, and infocmp
# prints all three as `name@`.
#
# This section exists because a mutation found a hole: making ti_str treat
# -2 as absent SURVIVED the string comparison above, since that comparison
# only looks at `s ` lines and a cancelled capability emits `s@`. Five
# cancelled strings and four cancelled numbers/booleans are in this corpus,
# so the hole was real rather than theoretical.
ncancel=0
nbad=0
for f in $corpus; do
	t=${f##*/}
	"$TERMINFO_BIN" -d "$f" | sed -n 's/^x\{0,1\}[bns]@ \(.*\)/\1 @/p' \
		| sort > "$work/cgot"
	infocmp -x -1 "$t" 2>/dev/null | python3 "$here/caps-hex.py" \
		| awk '$2=="@"' | sort > "$work/cwant"
	ncancel=$((ncancel + $(grep -c . < "$work/cgot")))
	if [ -n "$(comm -3 "$work/cgot" "$work/cwant")" ]; then
		nbad=$((nbad+1))
		[ "$nbad" -le 3 ] && comm -3 "$work/cgot" "$work/cwant"
	fi
done
[ "$nbad" -eq 0 ] \
	&& ok "cancelled capabilities are infocmp's ($ncancel across $nterm terminals)" \
	|| bad "cancelled: $nbad terminals disagree with infocmp, $ncancel compared"
# Without this, the whole section above would pass on a corpus containing no
# cancelled capability at all -- which is how the hole it was written for
# stayed hidden.
[ "$ncancel" -gt 0 ] \
	&& ok "cancelled: $ncancel exist, so -2 is distinguished from -1 on real data" \
	|| bad "no cancelled capability in the corpus, so -2 vs -1 is untested"

printf '\n--- 05 the ncurses extended-capability section\n'
# The section term(5) does not describe in its original format and `infocmp
# -x` is the only thing that knows. Its values are already folded into the
# three comparisons above, on the xb/xn/xs prefixes, so they are checked
# against infocmp like every other capability. What is checked here is the
# SPLIT: which capabilities this reader found in the extended section rather
# than at a fixed index.
#
# The oracle for that is infocmp -x minus the predefined names, which come
# from term.h through derive-caps.py. Not from `diff infocmp infocmp -x`,
# which looks like the same thing and is not: infocmp hides the obsolete OT*
# capabilities until -x is given, so seven predefined names appear in that
# difference and would be demanded of the extended section.
#
# The name a reader has to get right here is not in the file at the offset
# the obvious reading gives. Extended names are stored after the extended
# string VALUES and their offsets are measured from there, so a reader that
# treats them as table offsets reports a name cut out of the middle of some
# value: decoding xterm that way named a boolean "\033[?2004l".
next=0
nextterms=0
nbad=0
ncollide=0
nhdr=0
for f in $corpus; do
	t=${f##*/}
	"$TERMINFO_BIN" -d "$f" \
		| sed -n 's/^x[bns]@\{0,1\} \([^ ]*\).*$/\1/p' \
		| sort -u > "$work/xgot"
	infocmp -x -1 "$t" 2>/dev/null \
		| sed -n 's/^	\([a-zA-Z0-9_]\{1,\}\)[=#@,].*$/\1/p' \
		| sort -u | comm -23 - "$work/predef" > "$work/xwant"
	next=$((next + $(grep -c . < "$work/xgot")))
	[ -s "$work/xgot" ] && nextterms=$((nextterms+1))
	# An extended name that is also a predefined one would be subtracted
	# out of xwant above and the comparison would then demand that we do
	# NOT report it. None exist here; if one ever did this check is what
	# says so, rather than the oracle quietly weakening.
	ncollide=$((ncollide + $(comm -12 "$work/xgot" "$work/predef" | grep -c . || true)))
	# The header's own counts, against the oracle's answer to the same
	# question: does this terminal have extended capabilities at all.
	esum=$("$TERMINFO_BIN" -i "$f" \
		| awk '$1=="extbools"||$1=="extnums"||$1=="extstrs"{n+=$2} END{print n+0}')
	[ "$esum" -gt 0 ] && nhdr=$((nhdr+1))
	if [ -n "$(comm -3 "$work/xgot" "$work/xwant")" ]; then
		nbad=$((nbad+1))
		[ "$nbad" -le 3 ] && comm -3 "$work/xgot" "$work/xwant" | head -6
	fi
done
if [ "$nbad" -ne 0 ]; then
	bad "extended: $nbad terminals disagree with infocmp -x, $next compared"
elif [ "$next" -le 400 ]; then
	bad "extended: only $next capabilities across $nterm terminals, under the 400 floor"
else
	ok "extended capabilities are infocmp -x's ($next across $nextterms of $nterm terminals)"
fi
[ "$ncollide" -eq 0 ] \
	&& ok "no extended name is also a predefined one, so the oracle's subtraction hides nothing" \
	|| bad "$ncollide extended names collide with predefined ones"
# Ties the five-short extended header to the oracle. A reader that located
# the section one byte out would still agree about the capabilities of the
# 15 entries that have no extended section at all, and this is the number
# that notices.
[ "$nhdr" -eq "$nextterms" ] \
	&& ok "the extended header is non-empty for exactly the $nhdr terminals infocmp -x adds capabilities to" \
	|| bad "header says $nhdr terminals have an extended section, infocmp -x says $nextterms"

# Loud about what this corpus cannot prove. ncurses stores the same
# sentinels in the extended section as in the main one (0 and 2 for a
# boolean, -1 and -2 for a number or a string offset), and nothing here
# exercises most of them.
nxabs=0
for f in $corpus; do
	es=$("$TERMINFO_BIN" -i "$f" | sed -n 's/^extstrs //p')
	ngot=$("$TERMINFO_BIN" -d "$f" | sed -n 's/^xs@\{0,1\} .*/x/p' | grep -c . || true)
	nxabs=$((nxabs + es - ngot))
done
printf 'note: %d extended string capabilities in this corpus are ABSENT (-1)\n' "$nxabs"
printf 'note: SKIP, no cancelled extended capability exists under %s, so the\n' "$TIDIR"
printf '      xb@/xn@/xs@ paths are written from the format and unproven here\n'

printf '\n--- 07 malformed files, so the bounds checks are watched to fail\n'
# PLAN item 07. Everything above establishes that correct files are read
# correctly. Nothing established that broken ones are refused: the cursor's
# bounds checking had never been watched to fail, which is the same as not
# knowing whether it works.
#
# The base is a real compiled entry copied out of the read-only corpus.
mal=$work/mal
mkdir -p "$mal"
mal_base=$mal/base.ti
cp "$(printf '%s\n' $corpus | head -1)" "$mal_base"
mal_n=$(wc -c < "$mal_base")

# The header gives the exact size of the part this parser reads, so the
# boundary between "truncated" and "merely missing the extended section" is
# computed rather than guessed. 12-byte header, names, booleans, pad to even,
# then two bytes per number and per string offset, then the string table.
eval "$("$TERMINFO_BIN" -i "$mal_base" |
	awk '$1=="names"||$1=="bools"||$1=="nums"||$1=="strs"||$1=="strtable"{
		printf "h_%s=%d\n", $1, $2 }')"
std=$((12 + h_names + h_bools))
std=$((std + (std % 2)))
std=$((std + h_nums * 2 + h_strs * 2 + h_strtable))

# Every byte through the header and the first sections, then a stride: a
# truncation is only interesting where a length or an offset is read.
mal_cases=0; mal_sig=0; mal_quiet=0; mal_taken=0; mal_first_ok=-1
i=0
while [ "$i" -lt "$mal_n" ]; do
	head -c "$i" "$mal_base" > "$mal/t.ti"
	for mode in -i -d; do
		err=$("$TERMINFO_BIN" $mode "$mal/t.ti" 2>&1 >/dev/null); rc=$?
		mal_cases=$((mal_cases + 1))
		[ "$rc" -ge 128 ] && mal_sig=$((mal_sig + 1))
		if [ "$rc" -eq 0 ]; then
			mal_taken=$((mal_taken + 1))
			[ "$mal_first_ok" -lt 0 ] && mal_first_ok=$i
		elif [ -z "$err" ]; then
			mal_quiet=$((mal_quiet + 1))
		fi
	done
	if [ "$i" -lt 240 ]; then i=$((i + 1)); else i=$((i + 17)); fi
done

[ "$mal_cases" -ge 400 ] && ok "truncation sweep ran ($mal_cases runs over $mal_n bytes, both modes)" \
	|| bad "truncation sweep only ran $mal_cases cases"
[ "$mal_sig" -eq 0 ] && ok "no truncation killed it on a signal" \
	|| bad "$mal_sig truncations died on a signal"
[ "$mal_quiet" -eq 0 ] && ok "every refusal said why" \
	|| bad "$mal_quiet truncations were refused with no diagnostic"
# The interesting assertion: the first accepted truncation is exactly the end
# of the sections this parser reads. Earlier is a file it should have
# refused; later is the extended section, which it does not read and whose
# absence is not an error. A single number pins both directions.
[ "$mal_first_ok" -eq "$std" ] && ok "accepts from byte $std, the exact end of the standard sections" \
	|| bad "first accepted truncation is $mal_first_ok, computed end of sections is $std"

# Header fields, each sabotaged on its own.
mal_hdr() {
	python3 -c 'import sys,struct
b=bytearray(open(sys.argv[1],"rb").read()); struct.pack_into("<h",b,int(sys.argv[3]),int(sys.argv[4]))
open(sys.argv[2],"wb").write(b)' "$mal_base" "$mal/h.ti" "$2" "$3"
	err=$("$TERMINFO_BIN" -d "$mal/h.ti" 2>&1 >/dev/null); rc=$?
	if [ "$rc" -eq 0 ]; then bad "$1: accepted"
	elif [ "$rc" -ge 128 ]; then bad "$1: died on a signal"
	elif [ -z "$err" ]; then bad "$1: refused with no diagnostic"
	else ok "$1"; fi
}
mal_hdr 'a wrong magic number is refused'          0  1234
mal_hdr 'a names size past the file is refused'    2  30000
mal_hdr 'an absurd boolean count is refused'       4  30000
mal_hdr 'an absurd number count is refused'        6  30000
mal_hdr 'an absurd string count is refused'        8  30000
mal_hdr 'a string table past the file is refused'  10 30000
mal_hdr 'a negative boolean count is refused'      4  -1
mal_hdr 'a negative string table size is refused'  10 -1

# A string offset pointing outside the table. This was accepted, silently:
# ti_str returned NULL for it, dump_strs skips NULL as "capability absent",
# and the file was reported valid with the capability simply missing -- a
# plausible answer about a broken file, which is the worst of the three
# possible outcomes because nothing tells you.
python3 -c 'import sys,struct
b=bytearray(open(sys.argv[1],"rb").read())
names,bools,nums,strs=struct.unpack_from("<hhhh",b,2)
off=12+names+bools; off+=off&1; off+=nums*2
struct.pack_into("<h",b,off+2*int(sys.argv[3]),int(sys.argv[4]))
open(sys.argv[2],"wb").write(b)' "$mal_base" "$mal/s.ti" 0 30000
err=$("$TERMINFO_BIN" -d "$mal/s.ti" 2>&1 >/dev/null); rc=$?
case "$rc:$err" in
0:*)  bad "a string offset past the table is accepted" ;;
*:)   bad "a string offset past the table is refused with no diagnostic" ;;
*)    ok  "a string offset past the table is refused: ${err#terminfo: }" ;;
esac

# The extended header, sabotaged the same way. Its five counts come out of
# the file like every other count after byte 12, and until item 05 nothing
# read them at all. `std` is the end of the standard sections, so the
# extended header starts at the next even byte.
ext_off=$((std + std % 2))
mal_hdr 'an absurd extended boolean count is refused'   $((ext_off))     30000
mal_hdr 'an absurd extended number count is refused'    $((ext_off + 2)) 30000
mal_hdr 'an absurd extended string count is refused'    $((ext_off + 4)) 30000
mal_hdr 'a negative extended string count is refused'   $((ext_off + 4)) -1
mal_hdr 'an extended string table past the file is refused' $((ext_off + 8)) 30000

# An extended NAME offset pointing outside the table. This is the offset
# that is measured from the end of the string values rather than from the
# start of the table, so it is the one a reader is most likely to resolve
# into whatever happens to be there instead of refusing.
#
# The base file is chosen for having extended strings at all: the first
# entry in the corpus has one extended boolean and no strings, so the only
# name offset in it is 0 and there is nothing to point past.
mal_x=$(for f in $corpus; do
		"$TERMINFO_BIN" -i "$f" | sed -n 's/^extstrs //p' \
			| while read -r n; do [ "$n" -gt 4 ] && echo "$f"; done
	done | head -1)
if [ -z "$mal_x" ]; then
	bad "SKIP: no entry under $TIDIR has extended strings, so the name-offset bound is untested"
else
	cp "$mal_x" "$mal/x.ti"
	python3 -c 'import sys,struct
b=bytearray(open(sys.argv[1],"rb").read())
magic,names,bools,nums,strs,strsz=struct.unpack_from("<6h",b,0)
ns=4 if magic==0o1036 else 2
off=12+names+bools; off+=off&1; off+=nums*ns+strs*2+strsz; off+=off&1
eb,en,es,eitems,esz=struct.unpack_from("<5h",b,off); off+=10
off+=eb; off+=off&1; off+=en*ns
# The first NAME offset sits just past the es value offsets.
struct.pack_into("<h",b,off+2*es,int(sys.argv[3]))
open(sys.argv[2],"wb").write(b)' "$mal/x.ti" "$mal/xn.ti" 30000
	err=$("$TERMINFO_BIN" -d "$mal/xn.ti" 2>&1 >/dev/null); rc=$?
	case "$rc:$err" in
	0:*)  bad "an extended name offset past the table is accepted" ;;
	*:)   bad "an extended name offset past the table is refused with no diagnostic" ;;
	*)    ok  "an extended name offset past the table is refused: ${err#terminfo: }" ;;
	esac
	if "$TERMINFO_BIN" -d "$mal/x.ti" >/dev/null 2>&1; then
		ok "the unmodified ${mal_x##*/} still parses, so the sabotage is what was refused"
	else
		bad "the unmodified ${mal_x##*/} does not parse"
	fi
fi

# And the control: the file it was all derived from still parses.
if "$TERMINFO_BIN" -d "$mal_base" >/dev/null 2>&1; then
	ok "the unmodified base file still parses, so the sabotage is what was refused"
else
	bad "the unmodified base file does not parse"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
