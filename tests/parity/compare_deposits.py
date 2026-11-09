#!/usr/bin/env python3
"""Compare two deposit folders under the parity contract (spec section 7).

Usage:  python compare_deposits.py DEPOSIT_A DEPOSIT_B
Exit 0 when they agree. Prints every difference it finds.

  byte-identical   metadata/*_variables|valuelabels|chars|dataset|frequencies.csv, setup/*
  same values      data/*.csv (numbers at stored precision, strings exact)
  within 1e-6      metadata/*_summary.csv
  same after masking writer/time fields   datapackage.json, codebook/*_ddi.xml, codebook/*_codebook.md
"""

import csv
import json
import math
import os
import re
import sys

BYTE_TABLES = ("variables", "valuelabels", "chars", "dataset", "frequencies")


def read_rows(p):
    with open(p, encoding="utf-8", newline="") as fh:
        return list(csv.reader(fh))


def num(s):
    if s == "" or re.fullmatch(r"\.[a-z]?", s):
        return s
    try:
        return float(s)
    except ValueError:
        return s


def close(a, b, tol=1e-6):
    if isinstance(a, float) and isinstance(b, float):
        return a == b or abs(a - b) <= tol * max(abs(a), abs(b))
    return a == b


def compare(a, b):
    problems = []
    stems = sorted(f[:-14] for f in os.listdir(os.path.join(a, "metadata")) if f.endswith("_variables.csv"))
    stems_b = sorted(f[:-14] for f in os.listdir(os.path.join(b, "metadata")) if f.endswith("_variables.csv"))
    if stems != stems_b:
        return ["datasets differ: %s vs %s" % (stems, stems_b)]
    for ds in stems:
        for tab in BYTE_TABLES:
            pa = os.path.join(a, "metadata", "%s_%s.csv" % (ds, tab))
            pb = os.path.join(b, "metadata", "%s_%s.csv" % (ds, tab))
            if os.path.exists(pa) != os.path.exists(pb):
                problems.append("%s_%s.csv exists in only one deposit" % (ds, tab))
            elif os.path.exists(pa) and open(pa, "rb").read() != open(pb, "rb").read():
                ra, rb = read_rows(pa), read_rows(pb)
                diff = [(i, x, y) for i, (x, y) in enumerate(zip(ra, rb)) if x != y]
                problems.append("%s_%s.csv differs (%d vs %d rows); first: %s" % (
                    ds, tab, len(ra), len(rb), str(diff[:2])[:400]))
        for lang in ("do", "R", "py"):
            pa = os.path.join(a, "setup", "%s_setup.%s" % (ds, lang))
            pb = os.path.join(b, "setup", "%s_setup.%s" % (ds, lang))
            if open(pa, "rb").read() != open(pb, "rb").read():
                problems.append("setup/%s_setup.%s differs" % (ds, lang))
        pa = os.path.join(a, "metadata", ds + "_summary.csv")
        pb = os.path.join(b, "metadata", ds + "_summary.csv")
        if os.path.exists(pa) and os.path.exists(pb):
            for x, y in zip(read_rows(pa), read_rows(pb)):
                if not all(close(num(p), num(q)) for p, q in zip(x, y)):
                    problems.append("%s_summary.csv: %s vs %s" % (ds, x, y))
        da, db = os.path.join(a, "data", ds + ".csv"), os.path.join(b, "data", ds + ".csv")
        if os.path.exists(da) and os.path.exists(db):
            ra, rb = read_rows(da), read_rows(db)
            if len(ra) != len(rb):
                problems.append("data/%s.csv: %d vs %d rows" % (ds, len(ra), len(rb)))
            else:
                import struct
                types = [r[3] for r in read_rows(os.path.join(a, "metadata", ds + "_variables.csv"))[1:]]

                def f32(v):
                    return struct.unpack("f", struct.pack("f", v))[0] if isinstance(v, float) else v

                nd = 0
                for i, (x, y) in enumerate(zip(ra, rb)):
                    for j, (p, q) in enumerate(zip(x, y)):
                        u, w = num(p), num(q)
                        if i > 0 and j < len(types) and types[j] == "float":
                            u, w = f32(u), f32(w)
                        if u != w:
                            nd += 1
                            if nd <= 3:
                                problems.append("data/%s.csv row %d col %d: %r vs %r" % (ds, i, j, p, q))
                if nd > 3:
                    problems.append("data/%s.csv: %d value differences in all" % (ds, nd))
        for rel in ("codebook/%s_ddi.xml" % ds, "codebook/%s_codebook.md" % ds):
            pa, pb = os.path.join(a, rel), os.path.join(b, rel)
            if os.path.exists(pa) != os.path.exists(pb):
                problems.append("%s exists in only one deposit" % rel)
                continue
            ta, tb = open(pa, encoding="utf-8").read(), open(pb, encoding="utf-8").read()
            if ta != tb:
                la, lb = ta.split("\n"), tb.split("\n")
                bad = [(i, x, y) for i, (x, y) in enumerate(zip(la, lb)) if x != y and not stat_line_close(x, y)]
                if bad or len(la) != len(lb):
                    problems.append("%s differs: %s" % (rel, str(bad[:2])[:400]))
    ja = mask(json.load(open(os.path.join(a, "datapackage.json"), encoding="utf-8")))
    jb = mask(json.load(open(os.path.join(b, "datapackage.json"), encoding="utf-8")))
    if ja != jb:
        problems.append("datapackage.json differs after masking")
    return problems


def stat_line_close(x, y):
    """Lines that differ only in numbers within tolerance count as equal."""
    nx = re.split(r"(-?\d[\d.]*(?:e[-+]\d+)?)", x)
    ny = re.split(r"(-?\d[\d.]*(?:e[-+]\d+)?)", y)
    if len(nx) != len(ny):
        return False
    for i, (p, q) in enumerate(zip(nx, ny)):
        if i % 2 == 0:
            if p != q:
                return False
        elif not close(num(p), num(q)):
            return False
    return True


def mask(d):
    d = dict(d)
    d.pop("created", None)
    d.pop("name", None)
    return d


if __name__ == "__main__":
    probs = compare(sys.argv[1], sys.argv[2])
    for p in probs:
        print("DIFF", p)
    print("parity: %s (%s vs %s)" % ("OK" if not probs else "%d differences" % len(probs), sys.argv[1], sys.argv[2]))
    sys.exit(1 if probs else 0)
