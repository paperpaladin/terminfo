#!/bin/sh
# terminfo test suite.
#
# The oracle is ncurses, used as three separate authorities invoked as
# subprocesses: `infocmp` for what every capability of every terminal on this
# machine should be, `tic` for the source round-trip, and `tput` for what a
# parameterised string evaluates to. Nothing here compares our output against
# a number anybody writing this harness worked out by hand.
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
command -v tic     >/dev/null || { echo "tic not found; no oracle"; exit 1; }
command -v tput    >/dev/null || { echo "tput not found; no oracle"; exit 1; }
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
# number or a string -- so cancellations are compared as a kind-agnostic set
# later, once numbers and strings exist, rather than guessed at here.
#
# At this commit the predefined booleans are a strict subset of infocmp's
# list, because the extended section (which holds AX, XT, U8 and friends) is
# not read yet. Subset still bites: a wrong name or a shifted index drops
# straight out of it.
nbool=0
nbad=0
for f in $corpus; do
	t=${f##*/}
	infocmp -x -1 "$t" 2>/dev/null 		| sed -n 's/^	\([a-zA-Z0-9_]*\)\(@\{0,1\}\),$/\1\2/p' 		| sort > "$work/want"
	"$TERMINFO_BIN" -d "$f" 		| sed -n 's/^b \(.*\)$/\1/p;s/^b@ \(.*\)$/\1@/p' 		| sort > "$work/got"
	if [ -z "$(comm -13 "$work/want" "$work/got")" ]; then
		nbool=$((nbool + $(grep -c . < "$work/got")))
	else
		nbad=$((nbad+1))
		[ "$nbad" -le 3 ] && comm -13 "$work/want" "$work/got" | head -6
	fi
done
[ "$nbad" -eq 0 ] && [ "$nbool" -gt 200 ] \
	&& ok "predefined booleans are infocmp's ($nbool across $nterm terminals)" \
	|| bad "booleans: $nbad terminals disagree with infocmp, $nbool compared"

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
	"$TERMINFO_BIN" -d "$f" | sed -n 's/^n //p' | sort > "$work/got"
	# Values above 32767 cannot be read at all by a 16-bit decode, so
	# they are counted separately: they are the ones that prove the
	# extended format is being read rather than merely accepted.
	nbig=$((nbig + $(awk '$2 > 32767' < "$work/got" | grep -c . || true)))
	if [ -z "$(comm -13 "$work/want" "$work/got")" ]; then
		nnum=$((nnum + $(grep -c . < "$work/got")))
	else
		nbad=$((nbad+1))
		[ "$nbad" -le 3 ] && comm -13 "$work/want" "$work/got" | head -6
	fi
done
[ "$nbad" -eq 0 ] && [ "$nnum" -gt 100 ] \
	&& ok "numbers are infocmp's ($nnum across all $nterm terminals, $nwide of them 32-bit)" \
	|| bad "numbers: $nbad terminals disagree with infocmp, $nnum compared"
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
# No -x here: the extended section is a separate item, and asking infocmp
# for extended capabilities would report 86 absences per terminal that are
# not defects.
nstr=0
nbad=0
nempty=0
for f in $corpus; do
	t=${f##*/}
	"$TERMINFO_BIN" -d "$f" | sed -n 's/^s //p' \
		| python3 "$here/caps-hex.py" --normalize | sort > "$work/sgot"
	# Drop the cancelled entries: caps-hex.py emits those as `name @` for
	# the section below, and they are not string VALUES. Comparing them
	# here would report every cancelled capability as a missing string.
	infocmp -1 "$t" 2>/dev/null \
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
[ "$nbad" -eq 0 ] && [ "$nstr" -gt 4000 ] \
	&& ok "string capabilities are infocmp's, byte for byte ($nstr across $nterm terminals)" \
	|| bad "strings: $nbad terminals disagree with infocmp, $nstr compared"
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
	"$TERMINFO_BIN" -d "$f" | sed -n 's/^[bns]@ \(.*\)/\1 @/p' \
		| sort > "$work/cgot"
	infocmp -1 "$t" 2>/dev/null | python3 "$here/caps-hex.py" \
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
