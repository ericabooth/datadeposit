#!/usr/bin/env python3
"""Rebuild every golden deposit in Python and compare it with Stata's (spec section 7)."""
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python" / "src"))
from datadeposit import datadeposit  # noqa: E402

bad = 0
for ds in ("survey_edge", "auto", "nlsw88"):
    out = ROOT / "tests" / "out" / "parity_py" / ds
    datadeposit(str(ROOT / "tests" / "fixtures" / (ds + ".dta")), to=str(out), replace=True, quiet=True,
                title="Parity fixture " + ds, authors="Eric A. Booth", license="CC-BY-4.0")
    r = subprocess.run([sys.executable, str(ROOT / "tests" / "parity" / "compare_deposits.py"),
                        str(ROOT / "tests" / "golden" / ds), str(out)])
    bad += r.returncode != 0
sys.exit(1 if bad else 0)
