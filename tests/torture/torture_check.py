#!/usr/bin/env python3
"""Check the torture results: every language did what EXPECT says, and agrees with the others."""
import csv
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = ROOT / "tests" / "out" / "torture"
expect = {r["file"]: r["expect"] for r in csv.DictReader(open(BASE / "expected.csv"))}
langs = [l for l in ("stata", "py", "r") if (BASE / ("results_%s.csv" % l)).exists()]
bad = 0
res = {l: {r["file"]: r for r in csv.DictReader(open(BASE / ("results_%s.csv" % l), encoding="utf-8"))} for l in langs}
for l in langs:
    for f, e in expect.items():
        r = res[l].get(f)
        if r is None or r["outcome"] != e or (e == "ok" and r["detail"] != "passed"):
            print("FAIL %-6s %-24s expected %s, got %s" % (l, f, e, r and (r["outcome"] + " " + r["detail"])))
            bad += 1
    c = res[l].get("(crashed folder)")
    if c is None or c["detail"] != "passed use_refused=yes stray_removed=yes":
        print("FAIL %s crashed-folder recovery: %s" % (l, c and c["detail"]))
        bad += 1
    w = res[l]["(whole folder)"]
    if not w["detail"].startswith("passed"):
        print("FAIL %s whole folder: %s" % (l, w["detail"]))
        bad += 1
sub = {"stata": "stata", "py": "py", "r": "r"}
dep = "Eric's deposits/dépôt 2026"
for f, e in sorted(expect.items()):
    if e != "ok":
        continue
    key = f.replace(".", "_").replace(" ", "_")
    for a in langs[1:]:
        pa, pb = BASE / sub[langs[0]] / dep / key, BASE / sub[a] / dep / key
        r = subprocess.run([sys.executable, str(ROOT / "tests" / "parity" / "compare_deposits.py"), str(pa), str(pb)],
                           capture_output=True, text=True)
        if r.returncode:
            print("PARITY %s vs %s %s:\n%s" % (langs[0], a, f, r.stdout[-800:]))
            bad += 1
for a in langs[1:]:
    pa, pb = BASE / langs[0] / dep / "whole_folder", BASE / a / dep / "whole_folder"
    r = subprocess.run([sys.executable, str(ROOT / "tests" / "parity" / "compare_deposits.py"), str(pa), str(pb)],
                       capture_output=True, text=True)
    if r.returncode:
        print("PARITY whole folder %s vs %s:\n%s" % (langs[0], a, r.stdout[-800:]))
        bad += 1
n = sum(1 for e in expect.values() if e == "ok")
print("torture: %d inputs (%d deposit, %d refused) in %s; %s" % (
    len(expect), n, len(expect) - n, ", ".join(langs), "ALL AGREE" if not bad else "%d problems" % bad))
sys.exit(1 if bad else 0)
