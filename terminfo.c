/*
 * terminfo -- a reader for the compiled terminfo binary format.
 *
 * One C11 file, no ncurses and no libtinfo: the point of the exercise is to
 * read the bytes. `infocmp`, `tic` and `tput` appear only in the test
 * harness, as references, invoked as subprocesses.
 *
 * Two formats are handled. The legacy one (magic 0432, documented in
 * term(5)) stores numeric capabilities as signed 16-bit integers; the
 * extended-number format (magic 01036, ncurses 6.1 and later) stores them as
 * signed 32-bit integers and is otherwise identical. Both may carry the
 * ncurses extended-capability section after the string table, which is where
 * user-defined capabilities such as Smulx and setrgbf live.
 *
 * Everything that follows the twelve-byte header is addressed by an offset
 * or a count taken from the file, so every read goes through a cursor that
 * knows the file's length. The cursor's error flag is sticky: once set, all
 * further reads return zero and the caller checks once at the end.
 */
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAGIC_LEGACY 0432
#define MAGIC_NUM32  01036

/* term(5) limits. A file claiming more than this is malformed, not large. */
#define MAX_SECTION 4096
#define MAX_STRTAB  (1 << 20)

/* ncurses' sentinels, stored in the number array and the offset array. */
/* A pointer value that is not a string and not NULL, so ti_str can report
 * three outcomes through one return. Its address is the sentinel; its
 * contents are never read. */
static const char ti_cancel_marker;
#define TI_CANCEL_STR	(&ti_cancel_marker)

#define TI_ABSENT	(-1)
#define TI_CANCELLED	(-2)

static const char *prog = "terminfo";

static void diag(const char *fmt, ...)
#if defined(__GNUC__)
	__attribute__((format(printf, 1, 2)))
#endif
	;

#include <stdarg.h>

static void
diag(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "%s: ", prog);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

/* ------------------------------------------------------------------ cursor */

typedef struct {
	const unsigned char *base;
	size_t len;
	size_t at;
	int bad;			/* sticky */
} cursor;

static void
fail(cursor *c, const char *why)
{
	if (!c->bad) {
		c->bad = 1;
		diag("%s", why);
	}
}

/* Advance past n bytes and hand back a pointer to them, or NULL. */
static const unsigned char *
take(cursor *c, size_t n)
{
	const unsigned char *p;

	if (c->bad)
		return NULL;
	if (n > c->len - c->at) {	/* at <= len always, so no overflow */
		fail(c, "truncated: section runs past end of file");
		return NULL;
	}
	p = c->base + c->at;
	c->at += n;
	return p;
}

/*
 * Between sections the file is padded to an even byte boundary. Getting this
 * wrong shifts every number, every string offset and the whole extended
 * section by one byte, which is why it has its own sabotage in the harness.
 */
static void
align_even(cursor *c)
{
	if (c->at & 1u)
		(void) take(c, 1);
}

static int
le16(const unsigned char *p)
{
	return (int) (int16_t) ((unsigned) p[0] | ((unsigned) p[1] << 8));
}

/* The extended-number format's numeric cell. Signed, like le16, and the
 * sign matters for exactly the same reason: -1 and -2 are the two
 * not-a-value markers rather than values.
 *
 * Cast through int32_t rather than shifting into a signed int, because
 * p[3] << 24 with the top bit set is undefined when int is 32 bits -- the
 * one place where the obvious spelling of this is wrong. */
static long
le32(const unsigned char *p)
{
	uint32_t v = (uint32_t) p[0] | ((uint32_t) p[1] << 8)
		   | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);

	return (long) (int32_t) v;
}

/* --------------------------------------------------------- capability names
 * A compiled file stores capabilities positionally: the name of the
 * capability at index i of the boolean array is not in the file, it is in a
 * table every reader is expected to already have. The ordering is ncurses'
 * (the `Caps` file), and these tables were not typed out from a document.
 * They were derived from two things on this machine that we do not control:
 * /usr/include/term.h, which fixes the long name at every index
 * (`#define auto_left_margin CUR Booleans[0]`), and `tic` itself, asked
 * which index it puts a given short name at -- compile `probe, <name>,` and
 * read the resulting boolean count, which is the index plus one. See
 * t/derive-caps.py, which regenerates exactly what is pasted here.
 *
 * Indices at and past 37 (booleans), 33 (numbers) and 394 (strings) are
 * ncurses' obsolete capabilities, named OT-something. tic does write them
 * -- xterm here has 38 booleans, so OTbs is in the file -- and a reader that
 * stops at the "standard" counts gets the array length wrong.
 */
static const char *const bool_names[44] = {
	"bw", "am", "xsb", "xhp", "xenl", "eo", "gn", "hc", "km", "hs", "in", "da",
	"db", "mir", "msgr", "os", "eslok", "xt", "hz", "ul", "xon", "nxon", "mc5i",
	"chts", "nrrmc", "npc", "ndscr", "ccc", "bce", "hls", "xhpa", "crxm",
	"daisy", "xvpa", "sam", "cpix", "lpix", "OTbs", "OTns", "OTnc", "OTMT",
	"OTNL", "OTpt", "OTxr",
};
static const char *const num_names[39] = {
	"cols", "it", "lines", "lm", "xmc", "pb", "vt", "wsl", "nlab", "lh", "lw",
	"ma", "wnum", "colors", "pairs", "ncv", "bufsz", "spinv", "spinh", "maddr",
	"mjump", "mcs", "mls", "npins", "orc", "orl", "orhi", "orvi", "cps", "widcs",
	"btns", "bitwin", "bitype", "OTug", "OTdC", "OTdN", "OTdB", "OTdT", "OTkn",
};

static const char *const str_names[414] = {
	"cbt", "bel", "cr", "csr", "tbc", "clear", "el", "ed", "hpa", "cmdch", "cup",
	"cud1", "home", "civis", "cub1", "mrcup", "cnorm", "cuf1", "ll", "cuu1",
	"cvvis", "dch1", "dl1", "dsl", "hd", "smacs", "blink", "bold", "smcup",
	"smdc", "dim", "smir", "invis", "prot", "rev", "smso", "smul", "ech",
	"rmacs", "sgr0", "rmcup", "rmdc", "rmir", "rmso", "rmul", "flash", "ff",
	"fsl", "is1", "is2", "is3", "if", "ich1", "il1", "ip", "kbs", "ktbc", "kclr",
	"kctab", "kdch1", "kdl1", "kcud1", "krmir", "kel", "ked", "kf0", "kf1",
	"kf10", "kf2", "kf3", "kf4", "kf5", "kf6", "kf7", "kf8", "kf9", "khome",
	"kich1", "kil1", "kcub1", "kll", "knp", "kpp", "kcuf1", "kind", "kri",
	"khts", "kcuu1", "rmkx", "smkx", "lf0", "lf1", "lf10", "lf2", "lf3", "lf4",
	"lf5", "lf6", "lf7", "lf8", "lf9", "rmm", "smm", "nel", "pad", "dch", "dl",
	"cud", "ich", "indn", "il", "cub", "cuf", "rin", "cuu", "pfkey", "pfloc",
	"pfx", "mc0", "mc4", "mc5", "rep", "rs1", "rs2", "rs3", "rf", "rc", "vpa",
	"sc", "ind", "ri", "sgr", "hts", "wind", "ht", "tsl", "uc", "hu", "iprog",
	"ka1", "ka3", "kb2", "kc1", "kc3", "mc5p", "rmp", "acsc", "pln", "kcbt",
	"smxon", "rmxon", "smam", "rmam", "xonc", "xoffc", "enacs", "smln", "rmln",
	"kbeg", "kcan", "kclo", "kcmd", "kcpy", "kcrt", "kend", "kent", "kext",
	"kfnd", "khlp", "kmrk", "kmsg", "kmov", "knxt", "kopn", "kopt", "kprv",
	"kprt", "krdo", "kref", "krfr", "krpl", "krst", "kres", "ksav", "kspd",
	"kund", "kBEG", "kCAN", "kCMD", "kCPY", "kCRT", "kDC", "kDL", "kslt", "kEND",
	"kEOL", "kEXT", "kFND", "kHLP", "kHOM", "kIC", "kLFT", "kMSG", "kMOV",
	"kNXT", "kOPT", "kPRV", "kPRT", "kRDO", "kRPL", "kRIT", "kRES", "kSAV",
	"kSPD", "kUND", "rfi", "kf11", "kf12", "kf13", "kf14", "kf15", "kf16",
	"kf17", "kf18", "kf19", "kf20", "kf21", "kf22", "kf23", "kf24", "kf25",
	"kf26", "kf27", "kf28", "kf29", "kf30", "kf31", "kf32", "kf33", "kf34",
	"kf35", "kf36", "kf37", "kf38", "kf39", "kf40", "kf41", "kf42", "kf43",
	"kf44", "kf45", "kf46", "kf47", "kf48", "kf49", "kf50", "kf51", "kf52",
	"kf53", "kf54", "kf55", "kf56", "kf57", "kf58", "kf59", "kf60", "kf61",
	"kf62", "kf63", "el1", "mgc", "smgl", "smgr", "fln", "sclk", "dclk", "rmclk",
	"cwin", "wingo", "hup", "dial", "qdial", "tone", "pulse", "hook", "pause",
	"wait", "u0", "u1", "u2", "u3", "u4", "u5", "u6", "u7", "u8", "u9", "op",
	"oc", "initc", "initp", "scp", "setf", "setb", "cpi", "lpi", "chr", "cvr",
	"defc", "swidm", "sdrfq", "sitm", "slm", "smicm", "snlq", "snrmq", "sshm",
	"ssubm", "ssupm", "sum", "rwidm", "ritm", "rlm", "rmicm", "rshm", "rsubm",
	"rsupm", "rum", "mhpa", "mcud1", "mcub1", "mcuf1", "mvpa", "mcuu1", "porder",
	"mcud", "mcub", "mcuf", "mcuu", "scs", "smgb", "smgbp", "smglp", "smgrp",
	"smgt", "smgtp", "sbim", "scsd", "rbim", "rcsd", "subcs", "supcs", "docr",
	"zerom", "csnm", "kmous", "minfo", "reqmp", "getm", "setaf", "setab", "pfxl",
	"devt", "csin", "s0ds", "s1ds", "s2ds", "s3ds", "smglr", "smgtb", "birep",
	"binel", "bicr", "colornm", "defbi", "endbi", "setcolor", "slines", "dispc",
	"smpch", "rmpch", "smsc", "rmsc", "pctrm", "scesc", "scesa", "ehhlm",
	"elhlm", "elohlm", "erhlm", "ethlm", "evhlm", "sgr1", "slength", "OTi2",
	"OTrs", "OTnl", "OTbc", "OTko", "OTma", "OTG2", "OTG3", "OTG1", "OTG4",
	"OTGR", "OTGL", "OTGU", "OTGD", "OTGH", "OTGV", "OTGC", "meml", "memu", NULL,
};

/* ------------------------------------------------------------------- entry */

typedef struct {
	unsigned char *raw;
	size_t rawlen;

	int magic;
	int numsize;			/* 2 legacy, 4 extended-number */

	int nnames, nbool, nnum, nstr, strsz;
	const char *names;		/* NUL-terminated, "name|alias|desc" */
	const unsigned char *bools;
	const unsigned char *nums;
	const unsigned char *offs;
	const char *strtab;

	int has_ext;
	int eb, en, es, eitems, esz;
	const unsigned char *ebools;
	const unsigned char *enums;
	const unsigned char *eoffs;	/* es values, then eb+en+es names */
	const char *etab;
	int ebase;			/* names start here within etab */
} entry;

static unsigned char *
slurp(const char *path, size_t *outlen)
{
	FILE *f;
	unsigned char *buf = NULL;
	size_t cap = 0, got = 0;

	f = fopen(path, "rb");
	if (!f) {
		diag("%s: %s", path, strerror(errno));
		return NULL;
	}
	for (;;) {
		size_t n;

		if (got == cap) {
			unsigned char *nb;

			if (cap > (size_t) 16 << 20) {
				diag("%s: absurdly large for a terminfo file",
				     path);
				free(buf);
				fclose(f);
				return NULL;
			}
			cap = cap ? cap * 2 : 8192;
			nb = realloc(buf, cap);
			if (!nb) {
				diag("out of memory");
				free(buf);
				fclose(f);
				return NULL;
			}
			buf = nb;
		}
		n = fread(buf + got, 1, cap - got, f);
		got += n;
		if (n == 0)
			break;
	}
	if (ferror(f)) {
		diag("%s: %s", path, strerror(errno));
		free(buf);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*outlen = got;
	return buf;
}

static int
count_ok(cursor *c, int v, int limit, const char *what)
{
	if (v < 0 || v > limit) {
		char msg[128];

		snprintf(msg, sizeof msg, "bad %s count %d", what, v);
		fail(c, msg);
		return 0;
	}
	return 1;
}

/* ------------------------------------------- the ncurses extended section
 *
 * term(5)'s original format stops at the string table. ncurses appends a
 * section after it, relying on other implementations reading only as far as
 * the header's sizes say; term(5) on this machine documents the result under
 * "Extended Storage Format". It holds the user-defined capabilities (AX, XT,
 * Smulx, setrgbf) and, since nothing else can know them, their NAMES.
 *
 * Five 16-bit counts: extended booleans, extended numbers, extended strings,
 * the number of items stored in the extended string table, and the table's
 * size in bytes. Then the booleans one byte each, a pad to an even boundary,
 * the numbers at the same width as the main number array, then one 16-bit
 * offset per extended string value followed by one per NAME (booleans first,
 * then numbers, then strings), then the table.
 *
 * The name offsets are the trap in this layout. They are not offsets into
 * the table: they are offsets from the END of the string values, so reading
 * them the obvious way yields a name sliced out of the middle of some value.
 * Decoding xterm that way gave "\033[?2004l" as the name of a boolean. The
 * base is the total length of the values that are present, and the proof it
 * is right is external: the names this produces are exactly the ones
 * `infocmp -x` prints, across every entry on this machine that has the
 * section.
 *
 * The fourth count is of items actually STORED, so an absent value is not
 * one. screen.xterm-256color is the single entry here where that shows: 78
 * extended strings, one of them absent, and the field says 158 rather than
 * the 159 offsets that follow it. A reader taking that count as the length
 * of the offset array reads the whole array one short out of position.
 */

/* A NUL-terminated string at off in the extended string table. NULL if the
 * offset is outside the table or the string is not terminated inside it,
 * both of which are malformed rather than empty. */
static const char *
etab_at(const entry *e, size_t off, size_t *len)
{
	const void *nul;

	*len = 0;
	if (off >= (size_t) e->esz)
		return NULL;
	nul = memchr(e->etab + off, 0, (size_t) e->esz - off);
	if (!nul)
		return NULL;
	*len = (size_t) ((const char *) nul - (e->etab + off));
	return e->etab + off;
}

static int
ti_parse_ext(entry *e, cursor *c)
{
	const unsigned char *h;
	int i, nname, noffs;
	size_t base = 0;

	/*
	 * A file that ends at the string table has no extended section, and
	 * that is the normal case rather than a truncation: 15 of the 44
	 * entries here stop there. The pad is counted before the test, or a
	 * string table of odd length would look like one byte of a section
	 * that is not present.
	 */
	if (c->at + (c->at & 1u) >= c->len)
		return 1;
	align_even(c);
	h = take(c, 10);
	if (!h)
		return 0;

	e->has_ext = 1;
	e->eb = le16(h);
	e->en = le16(h + 2);
	e->es = le16(h + 4);
	e->eitems = le16(h + 6);
	e->esz = le16(h + 8);
	if (!count_ok(c, e->eb, MAX_SECTION, "extended boolean") ||
	    !count_ok(c, e->en, MAX_SECTION, "extended number") ||
	    !count_ok(c, e->es, MAX_SECTION, "extended string") ||
	    !count_ok(c, e->eitems, 4 * MAX_SECTION, "extended item") ||
	    !count_ok(c, e->esz, MAX_STRTAB, "extended string table"))
		return 0;

	nname = e->eb + e->en + e->es;
	noffs = nname + e->es;
	e->ebools = take(c, (size_t) e->eb);
	align_even(c);
	e->enums = take(c, (size_t) e->en * (size_t) e->numsize);
	e->eoffs = take(c, (size_t) noffs * 2);
	e->etab = (const char *) take(c, (size_t) e->esz);
	if (c->bad)
		return 0;

	/* Walk the values first: they are checked for the same reasons the
	 * main offset array is, and the walk is what produces the base the
	 * names are measured from. */
	for (i = 0; i < e->es; i++) {
		int off = le16(e->eoffs + (size_t) i * 2);
		size_t n;

		if (off == TI_ABSENT || off == TI_CANCELLED)
			continue;
		if (off < 0 || !etab_at(e, (size_t) off, &n)) {
			char msg[128];

			snprintf(msg, sizeof msg, "extended string %d has "
				 "offset %d, outside a %d-byte extended string "
				 "table or unterminated in it", i, off,
				 e->esz);
			fail(c, msg);
			return 0;
		}
		base += n + 1;
	}
	e->ebase = (int) base;

	for (i = 0; i < nname; i++) {
		int off = le16(e->eoffs + ((size_t) e->es + (size_t) i) * 2);
		size_t n;

		if (off < 0 || !etab_at(e, base + (size_t) off, &n)) {
			char msg[128];

			snprintf(msg, sizeof msg, "extended capability name "
				 "%d has offset %d from base %d, outside a "
				 "%d-byte extended string table or "
				 "unterminated in it", i, off, e->ebase,
				 e->esz);
			fail(c, msg);
			return 0;
		}
	}
	return 1;
}

/*
 * Parse the header and locate every section. The counts are read before any
 * of them is used, so a count that cannot be right is refused here rather
 * than by a later read that happens to run off the end.
 */
static int
ti_parse(entry *e, const char *path)
{
	cursor c;
	const unsigned char *h;

	memset(e, 0, sizeof *e);
	e->raw = slurp(path, &e->rawlen);
	if (!e->raw)
		return 0;

	c.base = e->raw;
	c.len = e->rawlen;
	c.at = 0;
	c.bad = 0;

	h = take(&c, 12);
	if (!h) {
		fail(&c, "too short for a terminfo header");
		goto out;
	}
	e->magic = le16(h);
	if (e->magic == MAGIC_LEGACY)
		e->numsize = 2;
	else if (e->magic == MAGIC_NUM32)
		e->numsize = 4;
	else {
		char msg[96];

		snprintf(msg, sizeof msg,
			 "not a terminfo file: magic 0%o, want 0432 or 01036",
			 (unsigned) (e->magic & 0xffff));
		fail(&c, msg);
		goto out;
	}
	e->nnames = le16(h + 2);
	e->nbool  = le16(h + 4);
	e->nnum   = le16(h + 6);
	e->nstr   = le16(h + 8);
	e->strsz  = le16(h + 10);

	if (!count_ok(&c, e->nnames, MAX_SECTION, "name") ||
	    !count_ok(&c, e->nbool, MAX_SECTION, "boolean") ||
	    !count_ok(&c, e->nnum, MAX_SECTION, "number") ||
	    !count_ok(&c, e->nstr, MAX_SECTION, "string") ||
	    !count_ok(&c, e->strsz, MAX_STRTAB, "string table"))
		goto out;
	if (e->nnames == 0) {
		fail(&c, "empty names section");
		goto out;
	}

	e->names = (const char *) take(&c, (size_t) e->nnames);
	e->bools = take(&c, (size_t) e->nbool);
	align_even(&c);
	e->nums = take(&c, (size_t) e->nnum * (size_t) e->numsize);
	e->offs = take(&c, (size_t) e->nstr * 2);
	e->strtab = (const char *) take(&c, (size_t) e->strsz);
	if (c.bad)
		goto out;

	if (e->names[e->nnames - 1] != '\0') {
		fail(&c, "names section is not NUL-terminated");
		goto out;
	}

	/*
	 * Validate the string-offset array here rather than where it is read.
	 *
	 * ti_str already refused an offset past the table and a string with no
	 * terminator inside it, and its comment says the first of those "is a
	 * malformed file rather than an empty capability" -- but it signalled
	 * both by returning NULL, which is also how it reports a capability
	 * that is legitimately absent. dump_strs does `if (!v) continue`. So a
	 * file with a corrupt offset was read as valid, printed without the
	 * capability, and exited 0 with no diagnostic: a plausible answer about
	 * a broken file, which is worse than a crash because nothing tells you.
	 *
	 * Checking at parse time is what count_ok already does for the counts,
	 * for the same reason stated there: refuse it here rather than at a
	 * later read that happens to cope. It also leaves ti_str's NULL
	 * meaning exactly one thing.
	 */
	{
		int i;

		for (i = 0; i < e->nstr; i++) {
			int off = le16(e->offs + (size_t) i * 2);

			if (off == TI_ABSENT || off == TI_CANCELLED)
				continue;
			if (off < 0 || (size_t) off >= (size_t) e->strsz) {
				char msg[96];

				snprintf(msg, sizeof msg, "string %d has "
					 "offset %d, outside a %d-byte string "
					 "table", i, off, e->strsz);
				fail(&c, msg);
				goto out;
			}
			if (!memchr(e->strtab + off, 0,
				    (size_t) e->strsz - (size_t) off)) {
				char msg[96];

				snprintf(msg, sizeof msg, "string %d at offset "
					 "%d is not terminated before the end "
					 "of the string table", i, off);
				fail(&c, msg);
				goto out;
			}
		}
	}

	ti_parse_ext(e, &c);

out:
	if (c.bad) {
		free(e->raw);
		e->raw = NULL;
		return 0;
	}
	return 1;
}

static void
ti_free(entry *e)
{
	free(e->raw);
	e->raw = NULL;
}

/* -------------------------------------------------------------- accessors */

/*
 * Booleans are one byte each. ncurses writes 0 for absent, 1 for present and
 * 2 (CANCELLED_BOOLEAN) for a capability explicitly cancelled with `cap@` in
 * the source. Those three are different facts: absent means the database has
 * nothing to say, cancelled means it says the terminal does not have it, and
 * infocmp prints only the last two.
 */
static int
ti_bool(const entry *e, int i)
{
	if (i < 0 || i >= e->nbool)
		return 0;
	return e->bools[i];
}

/*
 * Numbers are signed, and -1 and -2 are not values: -1 (ABSENT_NUMERIC)
 * means the database says nothing, -2 (CANCELLED_NUMERIC) means it says this
 * capability does not apply. infocmp prints nothing for the first and
 * `cap@` for the second, so conflating them loses a fact.
 *
 * Both widths are read here, chosen by the header's magic rather than by
 * guessing from the section size: numsize is 2 for magic 0432 and 4 for
 * magic 01036, and the two formats are otherwise identical. The sentinels
 * are the same two values in both, which is why TI_ABSENT and TI_CANCELLED
 * need no width of their own.
 */
static long
ti_num(const entry *e, int i)
{
	if (i < 0 || i >= e->nnum)
		return TI_ABSENT;
	if (e->numsize == 4)
		return le32(e->nums + (size_t) i * 4);
	return le16(e->nums + (size_t) i * 2);
}

/* A string capability is an OFFSET into the string table, not a string.
 *
 * Three things can be wrong here and only the first is obvious. The offset
 * may be -1 (absent) or -2 (cancelled), exactly like a number. It may point
 * past the end of the table, which is a malformed file rather than an empty
 * capability. And the table is not guaranteed to be NUL-terminated at its
 * end, so a string whose terminator is missing must not be read off the end
 * -- which is why the length is computed with memchr inside the table's own
 * bounds instead of with strlen.
 */
static const char *
ti_str(const entry *e, int i, size_t *len)
{
	int off;
	const char *p;
	const void *nul;

	*len = 0;
	if (i < 0 || i >= e->nstr)
		return NULL;
	off = le16(e->offs + (size_t) i * 2);
	if (off == TI_ABSENT)
		return NULL;
	if (off == TI_CANCELLED)
		return TI_CANCEL_STR;
	if (off < 0 || (size_t) off >= (size_t) e->strsz)
		return NULL;		/* malformed: offset past the table */
	p = e->strtab + off;
	nul = memchr(p, 0, (size_t) e->strsz - (size_t) off);
	if (!nul)
		return NULL;		/* unterminated at the table's end */
	*len = (size_t) ((const char *) nul - p);
	return p;
}

/* The name of extended capability i, counting booleans, then numbers, then
 * strings. Never NULL: ti_parse_ext refused the file if any name offset was
 * out of range, so by here every one of them resolves. */
static const char *
ext_name(const entry *e, int i)
{
	const char *p;
	size_t n;
	int off;

	if (i < 0 || i >= e->eb + e->en + e->es)
		return "";
	off = le16(e->eoffs + ((size_t) e->es + (size_t) i) * 2);
	p = etab_at(e, (size_t) e->ebase + (size_t) off, &n);
	return p ? p : "";
}

/* ------------------------------------------------------------------ output */

/* Emitted as HEX rather than in terminfo's own escape notation.
 *
 * A string capability is arbitrary bytes -- escapes, control characters,
 * sometimes a NUL-free binary blob -- and rendering it the way infocmp
 * renders it would mean comparing infocmp against an imitation of itself.
 * Hex has one spelling per byte string, so the harness can decode
 * infocmp's notation with a separate decoder and compare bytes to bytes.
 */
static void
dump_strs(const entry *e)
{
	int i;

	for (i = 0; i < e->nstr; i++) {
		size_t n;
		const char *v = ti_str(e, i, &n);
		const char *nm = i < 414 ? str_names[i] : NULL;

		if (!v)
			continue;
		if (v == TI_CANCEL_STR) {
			if (nm)
				printf("s@ %s\n", nm);
			else
				printf("s@? %d\n", i);
			continue;
		}
		if (!nm) {
			printf("s? %d ", i);
		} else {
			printf("s %s ", nm);
		}
		for (size_t k = 0; k < n; k++)
			printf("%02x", (unsigned char) v[k]);
		putchar('\n');
	}
}

static void
dump_nums(const entry *e)
{
	int i;

	for (i = 0; i < e->nnum; i++) {
		const char *nm = i < 39 ? num_names[i] : NULL;
		long v = ti_num(e, i);

		if (v == TI_ABSENT)
			continue;
		if (!nm) {
			printf("n? %d %ld\n", i, v);
			continue;
		}
		if (v == TI_CANCELLED)
			printf("n@ %s\n", nm);
		else if (v < 0)
			printf("n! %s %ld\n", nm, v);
		else
			printf("n %s %ld\n", nm, v);
	}
}


static void
dump_bools(const entry *e)
{
	int i;

	for (i = 0; i < e->nbool; i++) {
		const char *nm = i < 44 ? bool_names[i] : NULL;
		int v = ti_bool(e, i);

		if (v == 0)
			continue;
		if (!nm) {
			printf("b? %d %d\n", i, v);
			continue;
		}
		printf("%s %s\n", v == 2 ? "b@" : "b", nm);
	}
}

/*
 * The extended capabilities, on their own prefixes.
 *
 * They could be emitted as plain b/n/s lines, since infocmp -x prints them
 * in the same syntax as the predefined ones and the harness would compare
 * them without being told. Keeping them apart is what lets the harness ask
 * the sharper question: the set we label extended must be exactly the set
 * `infocmp -x` reports and plain `infocmp` does not. Merged in, a reader
 * that found no extended section at all would still have to be caught by
 * absence, and absence is the direction that has already gone wrong here
 * twice.
 *
 * The three sentinel conventions are the main sections': 0 and 2 for a
 * boolean, -1 and -2 for a number or a string offset. No entry in this
 * machine's corpus uses any of them except an absent string (one, in
 * screen.xterm-256color), so those branches are written from the format
 * rather than confirmed by the oracle, and the suite says so out loud.
 */
static void
dump_ext(const entry *e)
{
	int i;

	if (!e->has_ext)
		return;
	for (i = 0; i < e->eb; i++) {
		int v = e->ebools[i];

		if (v == 0)
			continue;
		printf("%s %s\n", v == 2 ? "xb@" : "xb", ext_name(e, i));
	}
	for (i = 0; i < e->en; i++) {
		const char *nm = ext_name(e, e->eb + i);
		long v = e->numsize == 4
			? le32(e->enums + (size_t) i * 4)
			: le16(e->enums + (size_t) i * 2);

		if (v == TI_ABSENT)
			continue;
		if (v == TI_CANCELLED)
			printf("xn@ %s\n", nm);
		else
			printf("xn %s %ld\n", nm, v);
	}
	for (i = 0; i < e->es; i++) {
		const char *nm = ext_name(e, e->eb + e->en + i);
		int off = le16(e->eoffs + (size_t) i * 2);
		const char *v;
		size_t n, k;

		if (off == TI_ABSENT)
			continue;
		if (off == TI_CANCELLED) {
			printf("xs@ %s\n", nm);
			continue;
		}
		v = etab_at(e, (size_t) off, &n);
		if (!v)
			continue;	/* refused at parse time */
		printf("xs %s ", nm);
		for (k = 0; k < n; k++)
			printf("%02x", (unsigned char) v[k]);
		putchar('\n');
	}
}

static int
mode_dump(const entry *e)
{
	printf("name %s\n", e->names);
	dump_bools(e);
	dump_nums(e);
	dump_strs(e);
	dump_ext(e);
	return 0;
}


static int
mode_info(const entry *e)
{
	printf("magic 0%o\n", (unsigned) e->magic);
	printf("numsize %d\n", e->numsize);
	printf("names %d\n", e->nnames);
	printf("bools %d\n", e->nbool);
	printf("nums %d\n", e->nnum);
	printf("strs %d\n", e->nstr);
	printf("strtable %d\n", e->strsz);
	printf("extbools %d\n", e->eb);
	printf("extnums %d\n", e->en);
	printf("extstrs %d\n", e->es);
	printf("extitems %d\n", e->eitems);
	printf("exttable %d\n", e->esz);
	printf("name %s\n", e->names);
	return 0;
}

static void
usage(void)
{
	fprintf(stderr,
		"usage: terminfo -i FILE              header facts\n"
		"       terminfo -d FILE              dump every capability\n");
}

int
main(int argc, char **argv)
{
	entry e;
	int rc;

	if (argc > 0 && argv[0][0])
		prog = "terminfo";
	if (argc < 3) {
		usage();
		return 2;
	}
	if (strcmp(argv[1], "-i") != 0 && strcmp(argv[1], "-d") != 0) {
		usage();
		return 2;
	}
	if (!ti_parse(&e, argv[2]))
		return 1;
	rc = argv[1][1] == 'i' ? mode_info(&e) : mode_dump(&e);
	ti_free(&e);
	return rc;
}
