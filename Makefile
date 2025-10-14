CC      ?= gcc
# -ffile-prefix-map keeps the build reproducible: without it -g writes the
# build directory into DWARF .debug_line_str and the binary differs between
# two checkouts of the same commit. Checked by unrepro (a sibling repo).
CFLAGS  ?= -std=c11 -O2 -g -Wall -Wextra -Wshadow -Wpedantic \
	   -ffile-prefix-map=$(CURDIR)=.

all: terminfo

terminfo: terminfo.c
	$(CC) $(CFLAGS) -o $@ $<

test: terminfo
	./t/run.sh

# Every offset in a compiled terminfo file is a 16-bit integer read straight
# out of the file and used to index a table, so the sanitizer build is a
# first-class target rather than a nicety. ASan catches the out-of-bounds
# read a missing bound check would hide; UBSan catches the signed shifts in
# the little-endian decode and the overflow paths in tparm's arithmetic.
terminfo-asan: terminfo.c
	$(CC) -std=c11 -g -O1 -fsanitize=address,undefined \
		-fno-omit-frame-pointer -Wall -Wextra -o $@ $<

# exitcode=86 is load-bearing. By default a sanitizer abort exits 1, and
# t/run.sh cannot tell that apart from the clean "exit 1, this file is
# malformed" that most of the corrupt-file sweep asserts -- so without it
# this target could not fail, and a heap overflow would be scored as a
# correct diagnostic. UBSan needs halt_on_error too, or it prints and
# carries on.
test-asan: terminfo-asan
	ASAN_OPTIONS=detect_leaks=1:exitcode=86 \
	UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:exitcode=86 \
	TERMINFO_BIN=$(CURDIR)/terminfo-asan ./t/run.sh

clean:
	rm -f terminfo terminfo-asan
	rm -rf t/tmp

.PHONY: all test test-asan clean
