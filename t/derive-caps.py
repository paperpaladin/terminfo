#!/usr/bin/env python3
"""Regenerate the capability-name tables pasted into terminfo.c.

A compiled terminfo file stores capabilities positionally; the name at each
index lives in a table the reader is expected to already have. Typing that
table out of a document would be inventing an authority, so it is derived
from two things on this machine that we do not control:

  * /usr/include/term.h, which fixes the long name at every index --
    `#define auto_left_margin CUR Booleans[0]` -- and so fixes the array
    lengths (44 booleans, 39 numbers, 414 strings in ncurses 6.5).

  * `tic` itself. Compile a one-capability entry and read the resulting
    count out of the header: `probe, am,` yields a boolean count of 2, so
    `am` is boolean index 1. A name tic does not recognise as predefined
    lands in the extended section instead and all three counts stay 0,
    which is also how the predefined/extended split is established rather
    than assumed.

Candidate short names come from the (long, short) pairs in `man 5 terminfo`
and from every name `infocmp -x` prints for a terminal on this machine. The
obsolete OT-prefixed capabilities are in neither, so those indices are
filled by probing OT plus one or two name characters -- 4032 candidates,
which tic answers in about a second.

Run from the repo root:  python3 t/derive-caps.py
It writes the three C arrays to stdout. Nothing in `make test` depends on
this script; the tables it produced are checked by the infocmp comparison,
over every capability of every terminal, on every run.
"""
import os
import re
import shutil
import string
import struct
import subprocess
import sys

WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tmp", "derive")
COUNTS = {"b": 44, "n": 39, "s": 414}


def term_h_longnames(path="/usr/include/term.h"):
    """{kind: {index: long_name}} straight out of ncurses' own header."""
    out = {"b": {}, "n": {}, "s": {}}
    kinds = {"Booleans": "b", "Numbers": "n", "Strings": "s"}
    pat = re.compile(r"^#define\s+(\w+)\s+CUR (Booleans|Numbers|Strings)\[(\d+)\]")
    for line in open(path):
        m = pat.match(line)
        if m:
            out[kinds[m.group(2)]][int(m.group(3))] = m.group(1)
    return out


def man_candidates():
    env = dict(os.environ, MANWIDTH="250")
    try:
        txt = subprocess.run(["man", "5", "terminfo"], capture_output=True,
                             text=True, env=env).stdout
    except OSError:
        return set()
    txt = re.sub(r"\x1b\[[0-9;]*m", "", txt)
    names = set()
    for line in txt.splitlines():
        f = line.split()
        if len(f) >= 3 and re.fullmatch(r"[a-z][a-z0-9_]*", f[0]) \
                and re.fullmatch(r"\w+", f[1]):
            names.add(f[1])
    return names


def infocmp_candidates(tidir="/usr/share/terminfo"):
    names = set()
    for dirpath, _, files in os.walk(tidir):
        for fn in files:
            if fn == "README":
                continue
            txt = subprocess.run(["infocmp", "-x", "-1", fn],
                                 capture_output=True, text=True).stdout
            for line in txt.splitlines():
                m = re.match(r"\t(\w+)[,#=@]", line)
                if m:
                    names.add(m.group(1))
    return names


def ask_tic(decls):
    """decls: [(tag, source declaration)] -> {tag: (nbool, nnum, nstr)}."""
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    src = os.path.join(WORK, "probe.src")
    out = os.path.join(WORK, "out")
    with open(src, "w") as fh:
        for i, (_, decl) in enumerate(decls):
            fh.write("zzp%05d|probe,\n\t%s,\n" % (i, decl))
    subprocess.run(["tic", "-x", "-o", out, src], capture_output=True)
    res = {}
    for i, (tag, _) in enumerate(decls):
        f = os.path.join(out, "z", "zzp%05d" % i)
        if os.path.exists(f):
            h = struct.unpack("<6h", open(f, "rb").read()[:12])
            res[tag] = (h[2], h[3], h[4])
    return res


def place(table, names):
    """Probe each name as a boolean, a number and a string; record the index."""
    unplaced = []
    for kind, suffix, slot in (("b", "", 2), ("n", "#1", 3), ("s", "=X", 4)):
        batch = [(n, n + suffix) for n in sorted(names)]
        for i in range(0, len(batch), 2000):
            for tag, counts in ask_tic(batch[i:i + 2000]).items():
                c = counts[slot - 2]
                if c and (c - 1) not in table[kind]:
                    table[kind][c - 1] = tag
    for n in sorted(names):
        if not any(n in t.values() for t in table.values()):
            unplaced.append(n)
    return unplaced


def emit(table, kind, cname):
    n = COUNTS[kind]
    print("static const char *const %s[%d] = {" % (cname, n))
    line = "\t"
    for i in range(n):
        tok = '"%s",' % table[kind][i] if i in table[kind] else "NULL,"
        if len(line) + len(tok) > 78:
            print(line.rstrip())
            line = "\t"
        line += tok + " "
    print(line.rstrip())
    print("};")


def main():
    longs = term_h_longnames()
    for kind, want in COUNTS.items():
        got = len(longs[kind])
        if got != want:
            sys.exit("term.h has %d %s indices, expected %d" % (got, kind, want))
    table = {"b": {}, "n": {}, "s": {}}
    place(table, man_candidates() | infocmp_candidates())
    # The obsolete capabilities are in no document here. Brute-force them.
    al = string.ascii_letters + string.digits + "_"
    place(table, {"OT" + a for a in al} |
                 {"OT" + a + b for a in al for b in al})
    for kind, cname in (("b", "bool_names"), ("n", "num_names"),
                        ("s", "str_names")):
        missing = [i for i in range(COUNTS[kind]) if i not in table[kind]]
        print("/* %s: %d of %d named; unnamed indices %r (term.h long names "
              "%r) */" % (cname, len(table[kind]), COUNTS[kind], missing,
                          [longs[kind][i] for i in missing]), file=sys.stderr)
        emit(table, kind, cname)


if __name__ == "__main__":
    main()
