"""Identify a file by its contents, not its name.

Shared folders hold .txt files that are really pipe-delimited tables, .csv
files saved in Latin-1, Stata files renamed to .txt, and code or notes beside
the data. sniff() reads the first 64 KB and says what the file is, so
datadeposit can read a table whatever it is called and explain why it skips
anything that is not one. The same rules are in the R and Stata versions.
"""

import os
import re

CODE_EXT = {".do", ".ado", ".r", ".rmd", ".qmd", ".py", ".ipynb", ".sas", ".sps", ".m", ".jl", ".sql",
            ".sh", ".md", ".tex", ".log", ".smcl", ".pdf", ".docx", ".doc", ".html", ".png", ".jpg",
            ".gif", ".svg", ".json", ".xml", ".yaml", ".yml"}
DELIMS = [",", "\t", "|", ";"]


class Sniff:
    def __init__(self, kind, why="", delim=None, encoding=None, decimal="."):
        self.kind = kind          # dta, dta_old, delimited, xlsx, xls, sav, parquet, rds, gzip, ...
        self.why = why            # a sentence for the user when the file is not readable as data
        self.delim = delim
        self.encoding = encoding
        self.decimal = decimal

    @property
    def is_data(self):
        return self.kind in ("dta", "dta_old", "delimited", "xlsx", "xls", "sav", "parquet", "rds", "gzip")

    def __repr__(self):
        return "Sniff(%s, %r)" % (self.kind, self.delim or self.why)


def _split_quoted(line, d):
    """Count fields in a line, respecting double quotes."""
    n, inq = 1, False
    for ch in line:
        if ch == '"':
            inq = not inq
        elif ch == d and not inq:
            n += 1
    return n


def sniff(path):
    ext = os.path.splitext(path)[1].lower()
    size = os.path.getsize(path)
    if size == 0:
        return Sniff("empty", "the file is empty")
    with open(path, "rb") as fh:
        head = fh.read(65536)
    if head.startswith(b"<stata_dta>"):
        return Sniff("dta")
    if len(head) > 2 and head[0] in (104, 105, 108, 110, 111, 113, 114, 115) and head[1] in (1, 2) and head[2] == 1:
        return Sniff("dta_old")
    if head.startswith(b"PK\x03\x04"):
        if b"xl/" in head or ext in (".xlsx", ".xlsm"):
            return Sniff("xlsx")
        return Sniff("zip", "the file is a zip archive; unzip it first")
    if head.startswith(b"\xd0\xcf\x11\xe0"):
        if ext in (".doc", ".ppt", ".msg"):
            return Sniff("document", "the file is an Office document, not a table")
        return Sniff("xls")
    if head.startswith(b"$FL2") or head.startswith(b"$FL3"):
        return Sniff("sav")
    if head.startswith(b"PAR1"):
        return Sniff("parquet")
    if head.startswith(b"%PDF"):
        return Sniff("document", "the file is a PDF; add it with include= to ship it in docs/")
    if head.startswith(b"\x89PNG") or head.startswith(b"\xff\xd8\xff") or head.startswith(b"GIF8"):
        return Sniff("document", "the file is an image; add it with include= to ship it in docs/")
    if head.startswith(b"\x1f\x8b"):
        if ext == ".rds":
            return Sniff("rds")
        return Sniff("gzip")
    if head[:5] in (b"RDX2\n", b"RDX3\n") or head[:2] in (b"X\n", b"A\n"):
        return Sniff("rds")
    if head[:2] in (b"\xff\xfe", b"\xfe\xff"):
        enc = "utf-16"
        text = head.decode(enc, errors="ignore")
    elif b"\x00" in head:
        return Sniff("binary", "the file holds binary data, not text, though its name ends in %s" % (ext or "nothing"))
    else:
        try:
            text = head.decode("utf-8-sig")
            enc = "utf-8-sig" if head.startswith(b"\xef\xbb\xbf") else "utf-8"
        except UnicodeDecodeError as err:
            # a cut multibyte character at the 64 KB boundary is still UTF-8
            if err.start > len(head) - 4 and len(head) == 65536:
                text = head[:err.start].decode("utf-8-sig")
                enc = "utf-8"
            else:
                text = head.decode("latin-1")
                enc = "latin-1"
    if ext in CODE_EXT:
        return Sniff("code", "the file is code or documentation (%s); add it with include= to ship it in docs/" % os.path.splitext(path)[1])
    import csv
    import io
    body = text if len(head) < 65536 else text[:text.rfind("\n") + 1] or text
    if not body.strip():
        return Sniff("empty", "the file holds only blank lines")

    def records(d):
        try:
            rows = [r for r in csv.reader(io.StringIO(body), delimiter=d) if any(x.strip() for x in r)]
        except csv.Error:
            return []
        return rows[:200]

    best = None
    for d in DELIMS:
        rows = records(d)
        if not rows:
            continue
        counts = [len(r) for r in rows]
        if counts[0] > 1 and all(c == counts[0] for c in counts):
            if best is None or counts[0] > best[1]:
                best = (d, counts[0], rows)
    if best is None:
        multi = [(d, records(d)) for d in DELIMS]
        multi = [(d, r) for d, r in multi if r and len(r[0]) > 1]
        if multi:
            d, rows = max(multi, key=lambda x: len(x[1][0]))
            bad = next(i for i, r in enumerate(rows) if len(r) != len(rows[0]))
            return Sniff("ragged", "record %d has %d fields but the header has %d (delimiter %r); "
                                   "fix the file or read it yourself" % (bad + 1, len(rows[bad]), len(rows[0]), d))
        rows = records(",")
        if len(rows) >= 1 and all(len(r) == 1 for r in rows) and ext in (".csv", ".tsv", ".txt", ".psv", ".dat") \
                and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,31}", rows[0][0].strip()) \
                and all(len(r[0]) <= 80 for r in rows):
            return Sniff("delimited", delim=",", encoding=enc)
        return Sniff("text", "the file is text with no consistent delimiter (comma, tab, pipe, or semicolon), "
                             "so it does not look like a table")
    d, rows = best[0], best[2]
    dec = "."
    if d == ";" and any(re.fullmatch(r"-?\d+,\d+", x.strip()) for r in rows[1:] for x in r):
        dec = ","
    return Sniff("delimited", delim=d, encoding=enc, decimal=dec)
