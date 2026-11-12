"""The four commands: datadeposit (create), deposit_use, deposit_verify, deposit_apply.

Each one does what the Stata subcommand of the same name does, with the same
options spelled in Python style (Stata maxsize() is max_size_gb=, onlarge()
is on_large=, nostats is stats=False, and so on).
"""

import glob
import os
import platform
import runpy
import shutil
import subprocess
import sys
import tempfile

import numpy as np

from . import core, dta, sources
from .core import meta_path

PACKAGE_VERSION = "0.1.0"
TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), "templates")
FORMATS = ("csv", "dta", "rds", "xlsx", "sav")


class DepositError(Exception):
    pass


def _say(quiet, *parts):
    if not quiet:
        print(*parts)


def _size(b):
    if b >= 1e9:
        return "%.1f GB" % (b / 1e9)
    if b >= 1e6:
        return "%.1f MB" % (b / 1e6)
    return "%d KB" % max(1, round(b / 1e3))


def _row_width(t):
    w = 0
    for c in t.columns:
        st = c.stata_type
        if st == "strL":
            w += 8 + (np.mean([len(s.encode("utf-8")) for s in c.values[:1000]]) if t.nobs else 0)
        elif st.startswith("str"):
            w += int(st[3:])
        else:
            w += {"byte": 1, "int": 2, "long": 4, "float": 4, "double": 8}[st]
    return w


def _estimate(t):
    """Estimated bytes of the .dta and .csv copies."""
    est_dta = t.nobs * _row_width(t) + 2000 * len(t.columns) + 4000
    n = min(t.nobs, 1000)
    if n == 0:
        return est_dta, 0
    sample = core.Table(t.name, [core.Column(c.name, c.stata_name, c.stata_type, c.format, c.label,
                                             c.value_labels, c.values[:n],
                                             None if c.ext is None else c.ext[:n]) for c in t.columns], n)
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "s.csv")
        core.write_data_csv(p, sample)
        b = os.path.getsize(p)
    return est_dta, b / n * t.nobs


def find_rscript(rscript=None):
    if (rscript is not None and str(rscript).lower() == "none") \
            or os.environ.get("DATADEPOSIT_RSCRIPT", "").lower() == "none":
        return None
    cands = [rscript, os.environ.get("DATADEPOSIT_RSCRIPT"), shutil.which("Rscript"),
             "/opt/homebrew/bin/Rscript", "/usr/local/bin/Rscript", "/usr/bin/Rscript"]
    cands += sorted(glob.glob("C:/Program Files/R/R-*/bin/Rscript.exe"), reverse=True)
    for c in cands:
        if not c:
            continue
        try:
            r = subprocess.run([c, "-e", "cat('datadeposit-ok')"], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            continue
        if "datadeposit-ok" in r.stdout:
            return c
    return None


def _is_deposit(folder):
    m = os.path.join(folder, "MANIFEST.json")
    if not os.path.exists(m):
        return False
    try:
        return "datadeposit" in core.read_manifest(folder)
    except ValueError:
        return False


def _check_finished(path):
    if not _is_deposit(path):
        raise DepositError("%s is not a datadeposit folder (no MANIFEST.json)" % path)
    if core.read_manifest(path).get("status") == "incomplete":
        raise DepositError("the deposit in %s did not finish; run datadeposit again with replace=True" % path)


def _prepare(to, replace, include):
    if os.path.isdir(to) and os.listdir(to):
        if not replace:
            raise DepositError("folder %s already exists; pass replace=True to overwrite an earlier deposit" % to)
        if not _is_deposit(to):
            raise DepositError("%s is not a datadeposit folder (no MANIFEST.json written by datadeposit); "
                               "replace only overwrites earlier deposits, so nothing was deleted" % to)
        man = core.read_manifest(to)
        if man.get("status") == "incomplete":
            # an unfinished deposit lists no files: remove what datadeposit writes
            print("datadeposit: an earlier deposit in this folder did not finish; replacing it")
            for sub in ("data", "metadata", "codebook", "setup", "docs"):
                d = os.path.join(to, sub)
                if os.path.isdir(d):
                    for f in os.listdir(d):
                        if os.path.isfile(os.path.join(d, f)):
                            os.remove(os.path.join(d, f))
            for f in ("README.md", "datapackage.json"):
                if os.path.isfile(os.path.join(to, f)):
                    os.remove(os.path.join(to, f))
        for f in man.get("files", []):
            p = os.path.join(to, f["path"])
            if os.path.isfile(p):
                os.remove(p)
        os.remove(os.path.join(to, "MANIFEST.json"))
        for sub in ("data", "metadata", "codebook", "setup", "docs"):
            d = os.path.join(to, sub)
            if os.path.isdir(d) and not os.listdir(d):
                os.rmdir(d)
    for sub in ("data", "metadata", "codebook", "setup") + (("docs",) if include else ()):
        os.makedirs(os.path.join(to, sub), exist_ok=True)
    # mark the folder as an unfinished deposit until MANIFEST.json is written
    core.spit(os.path.join(to, "MANIFEST.json"), '{"datadeposit": "1.0", "status": "incomplete", "files": []}\n')


def _write_templates(root, ds):
    for lang, fname in (("do", "setup.do"), ("R", "setup.R"), ("py", "setup.py")):
        with open(os.path.join(TEMPLATE_DIR, fname), encoding="utf-8", newline="") as fh:
            text = fh.read().replace("__DATASET__", ds)
        core.spit(os.path.join(root, "setup", "%s_setup.%s" % (ds, lang)), text)


def _codebook_xlsx(root, ds):
    try:
        import openpyxl
    except ImportError:
        return False
    wb = openpyxl.Workbook()
    wb.remove(wb.active)
    for tab in ("variables", "valuelabels", "chars", "dataset", "summary", "frequencies"):
        p = meta_path(root, ds, tab)
        if not os.path.exists(p):
            continue
        ws = wb.create_sheet(tab)
        for r in core.read_csv(p):
            ws.append([x if len(x) <= 32000 else x[:32000] + " [cut for Excel; full text in metadata/%s_%s.csv]"
                       % (ds, tab) for x in r])
    wb.save(os.path.join(root, "codebook", ds + "_codebook.xlsx"))
    return True


def _data_xlsx(root, t):
    try:
        import openpyxl
    except ImportError:
        return False
    if t.nobs > 1048575:
        return False
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "codes"
    ws2 = wb.create_sheet("labels")
    ws.append([c.name for c in t.columns])
    ws2.append([c.name for c in t.columns])
    texts = []
    for c in t.columns:
        if c.kind == "string":
            texts.append((list(c.values), list(c.values)))
            continue
        s = core._num_strings(c)
        codes = [None if x == "" else (x if x.startswith(".") else float(x)) if c.kind == "numeric" else x for x in s]
        labmap = {(float(v) if not isinstance(v, str) else v): l for v, l in t.value_label_sets.get(c.value_labels, [])}
        labs = [labmap.get(x, x) if c.value_labels else x for x in codes]
        texts.append((codes, labs))
    for r in range(t.nobs):
        ws.append([col[0][r] for col in texts])
        ws2.append([col[1][r] for col in texts])
    wb.save(os.path.join(root, "data", t.name + ".xlsx"))
    return True


def _rengine(root, ds, fmt, rscript):
    rs = find_rscript(rscript)
    if not rs:
        return False
    out = os.path.join(root, "data", "%s.%s" % (ds, fmt))
    if os.path.exists(out):
        os.remove(out)
    flag = "--save-rds" if fmt == "rds" else "--save-sav"
    r = subprocess.run([rs, os.path.join(root, "setup", ds + "_setup.R"), "--root", root, flag, out],
                       capture_output=True, text=True)
    if not os.path.exists(out):
        print("datadeposit: note: Rscript did not write %s.%s:\n%s" % (ds, fmt, r.stderr[-2000:]))
        return False
    return True


def _one(root, t, fmts, stats, rscript, quiet, engines):
    core.write_metadata(root, t)
    if stats:
        core.write_stats(root, t)
    _write_templates(root, t.name)
    okr = True
    for f in fmts:
        rel = "data/%s.%s" % (t.name, f)
        if f == "csv":
            core.write_data_csv(os.path.join(root, rel), t)
        elif f == "dta":
            dta.write(os.path.join(root, rel), t)
        elif f == "xlsx":
            if _data_xlsx(root, t):
                engines[rel] = "openpyxl"
            else:
                _say(quiet, "datadeposit: note: no .xlsx copy (openpyxl missing, or more rows than Excel allows)")
        elif f == "sav":
            try:
                import pyreadstat
                df = deposit_use(root, name=t.name, _quiet=True)
                pyreadstat.write_sav(df, os.path.join(root, rel),
                                     column_labels=df.attrs["column_names_to_labels"],
                                     variable_value_labels={k: {kk: vv for kk, vv in v.items()
                                                                if not isinstance(kk, str)}
                                                            for k, v in df.attrs["variable_value_labels"].items()})
                engines[rel] = "pyreadstat"
            except ImportError:
                _say(quiet, "datadeposit: note: no .sav copy (needs pyreadstat)")
    if "rds" in fmts:
        if _rengine(root, t.name, "rds", rscript):
            engines["data/%s.rds" % t.name] = "R via setup.R"
        else:
            okr = False
    core.write_codebook_md(root, t.name)
    core.write_ddi(root, t.name)
    if _codebook_xlsx(root, t.name):
        engines["codebook/%s_codebook.xlsx" % t.name] = "openpyxl"
    return okr


def datadeposit(data=None, to=None, *, name=None, files=None, folder=None, pattern="*.dta", formats=None,
                lean=False, nodata=False, replace=False, max_size_gb=5.0, allow_large=False, on_large="stop",
                title="", authors="", description="", license="", version=None, changes="", include=(),
                question=None, stats=True, verify=True, rscript=None, hash=True, meta=None, quiet=False):
    """Write an archive-ready deposit folder; see help(datadeposit) and the README.

    data       a DataFrame, a dict of name -> DataFrame, a path, or a list of paths
               (.dta read with full metadata; .sav, .csv, .xlsx, .parquet through pandas)
    to         the deposit folder (default <name>_deposit in the working directory)
    formats    data files to write, from csv dta rds xlsx sav (default csv dta rds)
    lean       keep the native file plus the csv; setup scripts cover the rest
    nodata     metadata, codebook, and setup scripts only
    max_size_gb, allow_large, on_large   the size check (see the README)
    """
    if lean and nodata:
        raise DepositError("lean and nodata cannot be combined")
    if on_large not in ("stop", "lean"):
        raise DepositError("on_large must be 'stop' or 'lean'")
    if isinstance(authors, (list, tuple)):
        authors = "; ".join(authors)
    if isinstance(include, str):
        include = [include]
    version_given = version is not None
    version = "1" if version is None else str(version)

    # ---- datasets
    items = []
    skipped = []
    if folder is not None:
        from .sniff import sniff
        found = sorted(p for p in glob.glob(os.path.join(folder, pattern)) if os.path.isfile(p))
        files = []
        for p in found:
            sn = sniff(p)
            if sn.is_data:
                files.append(p)
            else:
                skipped.append("%s (%s)" % (os.path.basename(p), sn.why))
        if not files:
            raise DepositError("no data files match %s in %s%s" % (
                pattern, folder, "; skipped: " + "; ".join(skipped) if skipped else ""))
    if files is not None or isinstance(data, (str, os.PathLike, list, tuple)):
        paths = files if files is not None else ([data] if isinstance(data, (str, os.PathLike)) else list(data))
        for p in paths:
            p = os.fspath(p)
            if not os.path.exists(p) and os.path.exists(p + ".dta"):
                p += ".dta"
            if not os.path.exists(p):
                raise DepositError("file %s not found" % p)
            items.append((name if (name and len(paths) == 1) else sources.stem_of(p), p))
        from_files = True
    else:
        from_files = False
        if data is None:
            raise DepositError("give a DataFrame, a dict of DataFrames, or file paths")
        if isinstance(data, dict):
            for k, v in data.items():
                items.append((sources.clean_name(k), v))
        else:
            items.append((sources.clean_name(name or "data"), data))
    # a DataFrame loaded with deposit_use: name, version, and folder follow the parent
    prov = ""
    if not from_files and len(items) == 1 and hasattr(items[0][1], "attrs"):
        prov = (items[0][1].attrs.get("datadeposit") or {}).get("provenance", "")
    if prov:
        pp = (prov.split("|") + ["", "", "", ""])[:4]
        if name is None and pp[3]:
            items[0] = (pp[3], items[0][1])
        if not version_given and pp[1].isdigit():
            version = str(int(pp[1]) + 1)
    seen, renamed = {}, []
    for k, (stem, src) in enumerate(items):
        if stem in seen:
            seen[stem] += 1
            new = "%s_%d" % (stem, seen[stem])
            renamed.append("%s would also be named %s; it is named %s in the deposit" % (
                os.path.basename(src) if isinstance(src, str) else stem, stem, new))
            items[k] = (new, src)
        else:
            seen[stem] = 1
    stems = [s for s, _ in items]
    if to is None:
        if len(items) > 1:
            raise DepositError("several datasets: say where the deposit goes with to=")
        # Without to=, the deposit goes to the working directory, not beside
        # the source file (that folder may be a data folder other code reads).
        # A new version of a loaded deposit goes beside its parent when the
        # parent's folder is still there.
        where = ""
        if prov and os.path.isdir(prov.split("|")[0]):
            where = os.path.dirname(prov.split("|")[0])
        suffix = "_deposit" if version == "1" else "_deposit_v" + version
        to = os.path.join(where, stems[0] + suffix)

    # ---- profile
    if formats is not None:
        if lean or nodata:
            raise DepositError("formats cannot be combined with lean or nodata")
        fmts = [f.lower() for f in ([formats] if isinstance(formats, str) else formats)]
        fmts = list(dict.fromkeys(fmts))
        for f in fmts:
            if f not in FORMATS:
                raise DepositError("formats: %s is not one of %s" % (f, " ".join(FORMATS)))
        if "csv" not in fmts:
            raise DepositError("formats must include csv: the csv is the portable copy every setup script reads")
        profile = "custom"
    elif nodata:
        profile, fmts = "nodata", []
    elif lean:
        profile, fmts = "lean", ["csv"] + (["dta"] if from_files and all(str(p).lower().endswith(".dta")
                                                                           for _, p in items) else [])
    else:
        profile, fmts = "full", ["csv", "dta", "rds"]

    # ---- load and size check (before writing anything)
    tables = []
    for stem, src in items:
        try:
            if isinstance(src, str):
                t = sources.read_any(src, stem)
            else:
                t = sources.from_dataframe(src, stem, meta=meta)
        except ValueError as e:
            raise DepositError(str(e))
        for n in t.notes:
            _say(quiet, "datadeposit: note: " + n)
        if question is not None:
            t.question_char = question
        tables.append(t)
    largest, largest_file, total_full, total_lean = 0.0, "", 0.0, 0.0
    for t in tables:
        e_dta, e_csv = _estimate(t)
        total_full += e_csv + 2 * e_dta
        total_lean += e_csv + e_dta
        for f in fmts:
            e = e_csv if f == "csv" else 1.3 * e_csv if f == "xlsx" else e_dta
            if e > largest:
                largest, largest_file = e, "data/%s.%s" % (t.name, f)
    limit = max_size_gb * 1e9
    size_override = "none"
    if largest > limit and profile not in ("lean", "nodata"):
        if allow_large:
            size_override = "allowlarge"
            _say(quiet, "datadeposit: note: %s will be about %s (allow_large)" % (largest_file, _size(largest)))
        elif on_large == "lean":
            size_override = "onlarge_lean"
            profile = "lean"
            fmts = ["csv"] + (["dta"] if from_files and all(str(p).lower().endswith(".dta") for _, p in items) else [])
            _say(quiet, "datadeposit: %s would be about %s, over the %s GB limit; on_large='lean' switched to "
                        "the lean profile (native file + .csv + setup scripts)" % (largest_file, _size(largest), max_size_gb))
        else:
            raise DepositError(
                "%s would be about %s, over the %s GB limit (max_size_gb).\n"
                "  Nothing was written. Choose one:\n"
                "    lean=True         keep the native file plus one .csv and the setup scripts (about %s in all)\n"
                "    nodata=True       codebook, metadata, and setup scripts only (no data copies)\n"
                "    allow_large=True  write every format anyway (about %s in all)\n"
                "  Or raise max_size_gb, or pass on_large='lean' so a deposit at the end of a script\n"
                "  switches to lean by itself when the data grow."
                % (largest_file, _size(largest), max_size_gb, _size(total_lean), _size(total_full)))
    elif profile == "lean" and largest > limit:
        size_override = "lean"

    for sk in skipped:
        _say(quiet, "datadeposit: skipped %s" % sk)
    for rn in renamed:
        _say(quiet, "datadeposit: note: " + rn)

    # ---- write
    if os.path.exists(to) and not os.path.isdir(to):
        raise DepositError("%s is a file, not a folder; choose another place for the deposit" % to)
    try:
        _prepare(to, replace, include)
    except OSError as e:
        raise DepositError("cannot write to %s (%s); check that the folder exists and that you may write there"
                           % (to, e.strerror or e))
    engines = {}
    derived = tables[0].provenance if tables else ""
    ok_rds = True
    for t in tables:
        if not _one(to, t, fmts, stats, rscript, quiet, engines):
            ok_rds = False
    try:
        import openpyxl  # noqa: F401
        no_xlsx = False
    except ImportError:
        no_xlsx = True
    for f in include:
        shutil.copy(f, os.path.join(to, "docs", os.path.basename(f)))
    info = dict(title=title, description=description, authors=authors, license=license, version=version,
                changes=changes, derived=derived, profile=profile, formats=fmts, package_version=PACKAGE_VERSION,
                software="Python " + platform.python_version(), engine="python", max_gb=max_size_gb,
                largest=largest, size_override=size_override)
    core.write_datapackage(to, stems, info)
    core.write_readme(to, stems, info)
    mhash = core.write_manifest(to, stems, info, engines, hash)

    verified = "skipped"
    if verify and profile == "nodata":
        verified = "not applicable (no data files)"
    elif verify and largest > 1e9:
        _say(quiet, "datadeposit: round-trip check skipped for data over 1 GB; run deposit_verify(%r)" % to)
    elif verify:
        ok = all(_roundtrip(to, s, quiet) for s in stems)
        verified = "passed" if ok else "FAILED"

    _say(quiet, "-" * 72)
    _say(quiet, "datadeposit wrote %s" % os.path.abspath(to))
    _say(quiet, "  profile %s, datasets: %s" % (profile, " ".join(stems)))
    for t in tables:
        _say(quiet, "  %s: %d obs, %d vars" % (t.name, t.nobs, len(t.columns)))
    if fmts:
        _say(quiet, "  data formats: %s" % " ".join(fmts))
    if "rds" in fmts and not ok_rds:
        _say(quiet, "  note: no .rds was written because R (Rscript) was not found. R users can still rebuild\n"
                    "    the data with setup/*_setup.R. To write the .rds here, install R from\n"
                    "    https://cloud.r-project.org, or pass rscript= or set DATADEPOSIT_RSCRIPT.\n"
                    "    Pass lean=True to stop asking for an .rds.")
    if no_xlsx:
        _say(quiet, "  note: no codebook .xlsx was written because openpyxl is not installed;\n"
                    "    install it with  python -m pip install openpyxl  (the csv and Markdown codebook are complete)")
    _say(quiet, "  Python round trip (csv + setup.py vs. the data): %s" % verified)
    _say(quiet, "-" * 72)
    if verified == "FAILED":
        raise DepositError("the round-trip check found differences; see the messages above")
    return {"path": os.path.abspath(to), "datasets": stems, "formats": fmts, "profile": profile,
            "verified": verified, "manifest_sha256": mhash, "largest_gb": largest / 1e9}


def deposit_codebook(data=None, to=None, **kw):
    """Metadata, codebook, and setup scripts only (datadeposit with nodata=True)."""
    kw["nodata"] = True
    return datadeposit(data, to, **kw)


def _stems(root):
    d = os.path.join(root, "metadata")
    return sorted(f[:-len("_variables.csv")] for f in os.listdir(d) if f.endswith("_variables.csv"))


def deposit_use(path, name=None, categoricals=False, _quiet=False):
    """Load a dataset from a deposit, with every label and characteristic in df.attrs."""
    _check_finished(path)
    stems = _stems(path)
    if name is None:
        if len(stems) > 1:
            raise DepositError("this deposit holds several datasets (%s); pick one with name=" % " ".join(stems))
        name = stems[0]
    elif name not in stems:
        raise DepositError("dataset %s is not in this deposit (it holds: %s)" % (name, " ".join(stems)))
    setup = os.path.join(path, "setup", name + "_setup.py")
    saved = sys.stderr
    try:
        if _quiet:
            sys.stderr = open(os.devnull, "w")
        df = runpy.run_path(setup)["load"](root=path, categoricals=categoricals)
    finally:
        if _quiet:
            sys.stderr.close()
        sys.stderr = saved
    man = core.read_manifest(path)
    df.attrs["datadeposit"]["provenance"] = "%s|%s|%s|%s" % (
        os.path.abspath(path), man.get("version", ""), core.sha256(os.path.join(path, "MANIFEST.json")), name)
    return df


def _roundtrip(root, ds, quiet=False):
    """Rebuild from the csv with setup.py and compare metadata tables and values."""
    ok = True
    if not os.path.exists(os.path.join(root, "data", ds + ".csv")):
        return True
    dd = dict(core.read_csv(meta_path(root, ds, "dataset"))[1:])
    df = deposit_use(root, ds, _quiet=True)
    t = sources.from_dataframe(df, ds, source_file=dd.get("source_file", ""))
    t.question_char = dd.get("question_char", "")
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "metadata"))
        core.write_metadata(td, t)
        for tab in ("variables", "valuelabels", "chars", "dataset"):
            a, b = meta_path(root, ds, tab), meta_path(td, ds, tab)
            if open(a, "rb").read() != open(b, "rb").read():
                _say(quiet, "round trip: %s_%s.csv rebuilt from the csv differs from the deposit" % (ds, tab))
                ok = False
    p = os.path.join(root, "data", ds + ".dta")
    if os.path.exists(p):
        ref = sources.from_dta(p, ds)
        for a, b in zip(t.columns, ref.columns):
            if a.kind == "string":
                same = list(a.values) == list(b.values)
            else:
                x, y = np.asarray(a.values, float), np.asarray(b.values, float)
                same = np.array_equal(x, y, equal_nan=True)
                ea = np.zeros(len(x), np.int8) if a.ext is None else a.ext
                eb = np.zeros(len(y), np.int8) if b.ext is None else b.ext
                same = same and np.array_equal(ea, eb)
            if not same:
                _say(quiet, "round trip: values of %s rebuilt from the csv differ from data/%s.dta" % (a.name, ds))
                ok = False
    return ok


def deposit_verify(path, hash=True, quiet=False):
    """Check every file against MANIFEST.json and rebuild each dataset from its csv."""
    _check_finished(path)
    man = core.read_manifest(path)
    bad = 0
    for f in man.get("files", []):
        p = os.path.join(path, f["path"])
        if not os.path.exists(p):
            _say(quiet, "missing: %s" % f["path"])
            bad += 1
        elif os.path.getsize(p) != f["bytes"]:
            _say(quiet, "size changed: %s" % f["path"])
            bad += 1
        elif hash and f.get("sha256") and core.sha256(p) != f["sha256"]:
            _say(quiet, "content changed: %s (sha256 differs)" % f["path"])
            bad += 1
    _say(quiet, "files: %d checked, %d problems" % (len(man.get("files", [])), bad))
    rt = True
    for ds in _stems(path):
        ok = _roundtrip(path, ds, quiet)
        rt = rt and ok
        _say(quiet, "round trip %s: %s" % (ds, "passed" if ok else "FAILED"))
    ok = bad == 0 and rt
    _say(quiet, "deposit_verify: %s" % ("all checks passed" if ok else "problems found"))
    return {"ok": ok, "files_bad": bad, "roundtrip_ok": rt}


def deposit_apply(df, source, name=None, types=False, chars=True):
    """Apply edited metadata tables (a deposit, its metadata folder, or a codebook .xlsx) to a DataFrame.

    Recognizes the optional columns new_name and drop in the variables table,
    the way iecodebook apply does. Returns a new DataFrame whose df.attrs carry
    the updated labels; deposit it again with datadeposit().
    """
    import pandas as pd
    if str(source).lower().endswith(".xlsx"):
        sheets = pd.read_excel(source, sheet_name=None, dtype=str, keep_default_na=False)
        V = sheets["variables"].to_dict("records")
        L = sheets.get("valuelabels", pd.DataFrame(columns=["set", "value", "label"])).to_dict("records")
        C = sheets.get("chars", pd.DataFrame(columns=["variable", "char", "text"])).to_dict("records")
    else:
        mdir = os.path.join(source, "metadata") if os.path.isdir(os.path.join(source, "metadata")) else source
        if name is None:
            st = sorted(f[:-14] for f in os.listdir(mdir) if f.endswith("_variables.csv"))
            if len(st) != 1:
                raise DepositError("pick a dataset with name= (found: %s)" % " ".join(st))
            name = st[0]
        V = core.table_dicts(os.path.join(mdir, name + "_variables.csv"))
        L = core.table_dicts(os.path.join(mdir, name + "_valuelabels.csv"))
        C = core.table_dicts(os.path.join(mdir, name + "_chars.csv"))
    t = sources.from_dataframe(df, name or "data")
    bysn = {c.stata_name: c for c in t.columns}
    byname = {c.name: c for c in t.columns}
    sets = {}
    for r in L:
        v = r["value"]
        sets.setdefault(r["set"], []).append((v if v.startswith(".") else int(float(v)), r["label"]))
    t.value_label_sets.update(sets)
    missing, drops, renames = [], [], {}
    for r in V:
        key = r.get("stata_name") or r.get("name")
        c = bysn.get(key) or byname.get(r.get("name", ""))
        if c is None:
            missing.append(key)
            continue
        c.label = r.get("label", c.label)
        if r.get("format"):
            c.format = r["format"]
        c.value_labels = r.get("value_labels", c.value_labels)
        if types and r.get("stata_type"):
            c.stata_type = r["stata_type"]
        if str(r.get("drop", "")).strip().lower() in ("1", "yes", "y", "x", "true"):
            drops.append(c)
        nn = str(r.get("new_name", "") or "").strip()
        if nn and nn != c.stata_name:
            renames[c.name] = nn
    if chars:
        for r in C:
            if "[cut for Excel; full text in" in r["text"]:
                continue
            if r["variable"] == "_dta":
                t.dta_chars = [(n, x) for n, x in t.dta_chars if n != r["char"]] + [(r["char"], r["text"])]
            elif r["variable"] in bysn:
                c = bysn[r["variable"]]
                c.chars = [(n, x) for n, x in c.chars if n != r["char"]] + [(r["char"], r["text"])]
    t.columns = [c for c in t.columns if c not in drops]
    for c in t.columns:
        if c.name in renames:
            c.name = c.stata_name = renames[c.name]
    print("deposit_apply: %d variables updated, %d value labels, %d characteristics"
          % (len(V) - len(missing), len(L), len(C) if chars else 0))
    if missing:
        print("  in the table but not in the data:", " ".join(missing))
    if drops:
        print("  dropped:", " ".join(c.name for c in drops))
    return to_frame(t)


def to_frame(t):
    """A Table as a DataFrame with the same df.attrs a deposit's setup.py produces."""
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "metadata"))
        os.makedirs(os.path.join(td, "data"))
        os.makedirs(os.path.join(td, "setup"))
        core.write_metadata(td, t)
        core.write_data_csv(os.path.join(td, "data", t.name + ".csv"), t)
        _write_templates(td, t.name)
        saved = sys.stderr
        sys.stderr = open(os.devnull, "w")
        try:
            df = runpy.run_path(os.path.join(td, "setup", t.name + "_setup.py"))["load"](root=td)
        finally:
            sys.stderr.close()
            sys.stderr = saved
    return df
