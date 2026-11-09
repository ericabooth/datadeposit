"""Command line:  python -m datadeposit survey.dta --to survey_deposit [--lean] [--replace]
                  python -m datadeposit verify survey_deposit
"""

import argparse
import sys

from . import api


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "verify":
        p = argparse.ArgumentParser(prog="python -m datadeposit verify")
        p.add_argument("path")
        p.add_argument("--nohash", action="store_true")
        a = p.parse_args(argv[1:])
        r = api.deposit_verify(a.path, hash=not a.nohash)
        return 0 if r["ok"] else 1
    p = argparse.ArgumentParser(prog="python -m datadeposit", description="Write an archive-ready data deposit.")
    p.add_argument("files", nargs="+", help=".dta, .sav, .csv, .xlsx, or .parquet files")
    p.add_argument("--to")
    p.add_argument("--name")
    p.add_argument("--formats", nargs="+")
    p.add_argument("--lean", action="store_true")
    p.add_argument("--nodata", action="store_true")
    p.add_argument("--replace", action="store_true")
    p.add_argument("--max-size-gb", type=float, default=5.0)
    p.add_argument("--allow-large", action="store_true")
    p.add_argument("--on-large", default="stop", choices=["stop", "lean"])
    p.add_argument("--title", default="")
    p.add_argument("--authors", default="")
    p.add_argument("--license", default="")
    p.add_argument("--version", default="1")
    p.add_argument("--changes", default="")
    p.add_argument("--nostats", action="store_true")
    p.add_argument("--noverify", action="store_true")
    a = p.parse_args(argv)
    try:
        api.datadeposit(files=a.files, to=a.to, name=a.name, formats=a.formats, lean=a.lean, nodata=a.nodata,
                        replace=a.replace, max_size_gb=a.max_size_gb, allow_large=a.allow_large,
                        on_large=a.on_large, title=a.title, authors=a.authors, license=a.license,
                        version=a.version, changes=a.changes, stats=not a.nostats, verify=not a.noverify)
    except api.DepositError as e:
        print("datadeposit:", e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
