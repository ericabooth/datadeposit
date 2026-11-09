#!/usr/bin/env python3
"""Deposit every torture input from Python and record the outcome."""
import csv
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python" / "src"))
from datadeposit import DepositError, datadeposit  # noqa: E402

BASE = ROOT / "tests" / "out" / "torture"
OUTDIR = BASE / "py" / "Eric's deposits" / "dépôt 2026"
rows = []
for name in sorted(p.name for p in (BASE / "inputs").iterdir()):
    key = name.replace(".", "_").replace(" ", "_")
    try:
        r = datadeposit(str(BASE / "inputs" / name), to=str(OUTDIR / key), replace=True, quiet=True)
        rows.append((name, "ok", r["verified"]))
    except DepositError as e:
        rows.append((name, "error", str(e).replace("\n", " ")[:200]))
r = datadeposit(folder=str(BASE / "inputs"), pattern="*", to=str(OUTDIR / "whole_folder"), replace=True, quiet=True)
rows.append(("(whole folder)", "ok", r["verified"] + " " + " ".join(r["datasets"])))
# a deposit that crashed halfway: use refuses it, replace cleans it up
crash = OUTDIR / "crashed"
(crash / "data").mkdir(parents=True, exist_ok=True)
(crash / "MANIFEST.json").write_text('{"datadeposit": "1.0", "status": "incomplete", "files": []}\n')
(crash / "data" / "stray.csv").write_text("x\n1\n")
try:
    from datadeposit import deposit_use
    deposit_use(str(crash))
    refused = "no"
except DepositError:
    refused = "yes"
r = datadeposit(str(ROOT / "tests" / "fixtures" / "auto.dta"), to=str(crash), replace=True, quiet=True)
gone = "yes" if not (crash / "data" / "stray.csv").exists() else "no"
rows.append(("(crashed folder)", "ok", "%s use_refused=%s stray_removed=%s" % (r["verified"], refused, gone)))
with open(BASE / "results_py.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["file", "outcome", "detail"])
    w.writerows(rows)
print("python: %d cases" % len(rows))
