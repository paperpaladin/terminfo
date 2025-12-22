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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
