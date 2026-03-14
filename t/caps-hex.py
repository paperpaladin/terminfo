#!/usr/bin/env python3
"""t/caps-hex.py -- infocmp's string capabilities, as hex bytes.

SPDX-License-Identifier: GPL-3.0-or-later

Reads `infocmp -1 -x` on stdin and writes "name hex" for every STRING
capability, so the harness can compare bytes against bytes.

Why this exists rather than making terminfo print infocmp's notation: a
string capability is arbitrary bytes, and terminfo's source notation has
several spellings for the same byte (\\E and \\e and \\033 are all ESC).
Emitting that notation from the reader under test and diffing the text
would compare infocmp against an imitation of itself, and would pass or
fail on spelling rather than on bytes. Hex has one spelling per byte.

The decoder here is deliberately NOT the inverse of anything in
terminfo.c: that reads an offset table out of a compiled file, this parses
escape sequences out of text. A bug common to both is not a bug one of
them could hide.

terminfo(5) defines the notation. The case worth naming is \\0: it does not
produce a NUL, because a NUL would terminate the string -- tic stores
\\200 instead, and infocmp prints it back as \\200.
"""
import re
import sys

SIMPLE = {
    "E": 0x1b, "e": 0x1b,       # escape, both spellings
    "n": 0x0a, "l": 0x0a,       # newline; \l is linefeed
    "r": 0x0d, "t": 0x09,
    "b": 0x08, "f": 0x0c,
    "s": 0x20,                  # space, so it survives the comma split
    "a": 0x07,
    "\\": 0x5c, "^": 0x5e, ",": 0x2c, ":": 0x3a,
}


def decode(text):
    """terminfo source notation -> bytes."""
    out = bytearray()
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt.isdigit():
                m = re.match(r"[0-7]{1,3}", text[i + 1:])
                if m:
                    out.append(int(m.group(0), 8) & 0xff)
                    i += 1 + len(m.group(0))
                    continue
            if nxt in SIMPLE:
                out.append(SIMPLE[nxt])
                i += 2
                continue
            out.append(ord(nxt) & 0xff)   # unknown escape: the byte itself
            i += 2
            continue
        if c == "^" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append(0x7f if nxt == "?" else (ord(nxt) & 0x1f))
            i += 2
            continue
        out.append(ord(c) & 0xff)
        i += 1
    return bytes(out)


# `acsc` is the one capability infocmp does not print as stored.
#
# It is a sequence of (from, to) byte pairs mapping the alternate character
# set, and infocmp SORTS those pairs before printing. Three terminals in
# this machine's corpus -- hurd and two rxvt-unicode variants -- store them
# in an order infocmp does not reproduce, with the identical multiset of
# pairs. The reader is right and infocmp is canonicalising, so comparing the
# byte sequences would fail on infocmp's rendering choice.
#
# Both sides are normalised through here, so the comparison is between the
# same information: the SET of pairs, which is what acsc means. Comparing
# the order would be asserting something terminfo(5) does not promise.
def normalize(name, hexstr):
    if name != "acsc" or len(hexstr) % 4:
        return hexstr
    return "".join(sorted(hexstr[i:i + 4] for i in range(0, len(hexstr), 4)))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--normalize":
        # Already "name hex" lines -- our own reader's output. Same
        # normalisation, so neither side gets a rule the other does not.
        # partition, not split: a capability can be defined as the EMPTY
        # string, which is not the same as being absent. Eterm defines smkx
        # and rmkx that way. split() collapses the empty field and the two
        # sides then disagree on a capability both of them read correctly.
        for line in sys.stdin.read().splitlines():
            if not line.strip():
                continue
            name, sep, hexstr = line.partition(" ")
            print("%s %s" % (name, normalize(name, hexstr.strip())))
        return 0
    body = sys.stdin.read()
    # infocmp -1 puts one capability per line, indented, comma-terminated.
    # A string capability is `name=value`; `name#value` is a number and
    # a bare `name` is a boolean, so neither belongs here.
    for line in body.splitlines():
        line = line.strip()
        if not line.endswith(",") or line.startswith("#"):
            continue
        line = line[:-1]
        # `name@` is a CANCELLED capability -- the database saying this one
        # does not apply, which is not the same as saying nothing about it.
        # infocmp prints it the same way for all three classes, so it is
        # emitted here as `name @` and the harness compares the whole
        # cancelled set at once rather than per class.
        if line.endswith("@") and re.fullmatch(r"[A-Za-z0-9_]+@", line):
            print("%s @" % line[:-1])
            continue
        if "=" not in line:
            continue
        name, _, value = line.partition("=")
        if not re.fullmatch(r"[A-Za-z0-9_]+", name):
            continue
        print("%s %s" % (name, normalize(name, decode(value).hex())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
