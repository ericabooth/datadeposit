"""Turn the things a Python user has into a datadeposit Table.

Sources: a Stata .dta file (read with full metadata by dta.py), a pandas
DataFrame loaded from a deposit (its df.attrs["datadeposit"] carries the exact
metadata, so a deposit can be re-deposited without loss), a DataFrame read by
pyreadstat (pass its meta object), or any other DataFrame (types and labels
are inferred, and pandas Categoricals become labelled codes).
"""

import os
import re

import numpy as np
import pandas as pd

from . import dta
from .core import Column, Table, EPOCH_D, EPOCH_MS

RESERVED = {"_dta", "_all", "_b", "byte", "_coef", "_cons", "double", "float", "if", "in", "int", "long", "_n",
            "_N", "_pi", "_pred", "_rc", "_skip", "strL", "using", "with"}
LIMITS = [("byte", -127, 100), ("int", -32767, 32740), ("long", -2147483647, 2147483620)]


def stem_of(path):
    base = os.path.basename(path)
    if base.lower().endswith(".gz"):
        base = base[:-3]
    if "." in base:
        base = base[:base.rindex(".")]
    return clean_name(base)


def clean_name(s):
    s = re.sub(r"[^A-Za-z0-9_-]", "_", str(s).strip())
    return s or "data"


def stata_names(names):
    """Valid, unique Stata names (32 characters, letters, digits, underscore)."""
    out, seen = [], set()
    for n in names:
        s = re.sub(r"[^A-Za-z0-9_]", "_", str(n))
        if not s or s[0].isdigit():
            s = "_" + s
        if s in RESERVED or re.fullmatch(r"str[0-9]+", s):
            s = s + "_"
        s = s[:32]
        base, k = s, 2
        while s in seen:
            suf = "_%d" % k
            s = base[:32 - len(suf)] + suf
            k += 1
        seen.add(s)
        out.append(s)
    return out


# ----------------------------------------------------------------------------
# .dta
# ----------------------------------------------------------------------------

def from_dta(path, name=None):
    r = dta.Reader(path)
    try:
        values, ext = r.data()
        by_var, dta_chars, prov = {}, [], ""
        for var, cn, text in r.chars:
            if var == "_dta":
                if cn == "datadeposit_source":
                    prov = text
                else:
                    dta_chars.append((cn, text))
            else:
                by_var.setdefault(var, []).append((cn, text))
        cols = []
        for i, nm in enumerate(r.names):
            t = r.types[i]
            tname = dta.TYPE_NAMES.get(t, "str%d" % t)
            chars = by_var.get(nm, [])
            lab = r.varlabels[i]
            full = [txt for cn, txt in chars if cn == "datadeposit_label"]
            if full and full[0][:80] == lab:
                lab = full[0]
            orig = [txt for cn, txt in chars if cn == "datadeposit_name"]
            chars = [(cn, txt) for cn, txt in chars if cn not in ("datadeposit_label", "datadeposit_name")]
            cols.append(Column(orig[0] if orig else nm, nm, tname, r.formats[i], lab, r.vlnames[i], values[nm], ext.get(nm), chars))
        return Table(name or stem_of(path), cols, r.N, r.label, r.value_labels, dta_chars, r.sortlist,
                     os.path.basename(path), provenance=prov)
    finally:
        del values
        r.close()


# ----------------------------------------------------------------------------
# DataFrame
# ----------------------------------------------------------------------------

def _int_type(x):
    """Smallest Stata integer type for float values that are all integers, else None."""
    v = x[~np.isnan(x)]
    if len(v) and not np.all(v == np.floor(v)):
        return None
    lo, hi = (v.min(), v.max()) if len(v) else (0, 0)
    for name, a, b in LIMITS:
        if lo >= a and hi <= b:
            return name
    return None


def _str_type(vals):
    w = max([len(s.encode("utf-8")) for s in vals] + [1])
    return "strL" if w > 2045 else "str%d" % w


def _default_format(t):
    if t.startswith("str") and t != "strL":
        return "%%%ds" % max(9, int(t[3:]))
    return {"byte": "%8.0g", "int": "%8.0g", "long": "%12.0g", "float": "%9.0g", "double": "%10.0g",
            "strL": "%9s"}[t]


def _to_text(s):
    return np.array(["" if (v is None or (isinstance(v, float) and np.isnan(v)) or v is pd.NA) else str(v)
                     for v in s], dtype=object)


def nan_tags(values):
    """Extended missing codes held inside NaNs: 0 for none, 1 (.a) to 26 (.z), or None when there are none."""
    a = np.ascontiguousarray(values, dtype=np.float64)
    bits = a.view(np.uint64)
    low = (bits & np.uint64(0xFF)).astype(np.int64)
    clean = (bits & np.uint64(0x0007FFFFFFFFFF00)) == 0
    k = np.where(np.isnan(a) & clean & (low >= 1) & (low <= 26), low, 0).astype(np.int8)
    return k if k.any() else None


def missing_codes(series):
    """The extended missing code of each value: '' for none, '.a' to '.z' otherwise.

    Works on numeric columns of a DataFrame loaded with deposit_use() or a
    deposit's setup.py, after any filtering, sorting, or merging.
    """
    if not pd.api.types.is_float_dtype(series):
        return pd.Series("", index=series.index, name=series.name)
    k = nan_tags(series.to_numpy(dtype=np.float64, copy=False) if str(series.dtype) == "float64"
                 else np.full(len(series), 0.0))
    if k is None:
        return pd.Series("", index=series.index, name=series.name)
    return pd.Series(["." + chr(96 + int(v)) if v else "" for v in k], index=series.index, name=series.name)


NUMBER = re.compile(r"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$")
STATA_MAX = 8.988465674311579e307
MISSING_TOKENS = {"", "NA", "N/A", "NaN", "nan", "null", "NULL", "."}


def _clean_frame(df, notes):
    """Fix what Stata cannot store, before any type is chosen, and say what changed."""
    if df.shape[1] == 0:
        raise ValueError("the data have no columns")
    if isinstance(df.columns, pd.MultiIndex):
        df = df.copy()
        df.columns = ["_".join(str(x) for x in c if str(x) != "") for c in df.columns]
        notes.append("multi-level column names were joined with underscores")
    if not all(isinstance(c, str) for c in df.columns):
        df = df.copy()
        df.columns = [str(c) for c in df.columns]
    dups = sorted({c for c in df.columns if list(df.columns).count(c) > 1})
    if dups:
        raise ValueError("column names must be unique; rename the repeated column(s): %s" % ", ".join(dups))
    out = None
    for c in df.columns:
        s = df[c]
        fixed = None
        if pd.api.types.is_datetime64_any_dtype(s) and getattr(s.dt, "tz", None) is not None:
            fixed = s.dt.tz_convert("UTC").dt.tz_localize(None)
            notes.append("%s had time zone %s; it was converted to UTC" % (c, s.dt.tz))
        elif pd.api.types.is_timedelta64_dtype(s):
            fixed = s.dt.total_seconds()
            notes.append("%s held time spans; they were stored as seconds" % c)
        elif pd.api.types.is_complex_dtype(s):
            fixed = s.astype(str)
            notes.append("%s held complex numbers; they were stored as text" % c)
        elif pd.api.types.is_integer_dtype(s) and not pd.api.types.is_bool_dtype(s):
            v = s.dropna()
            if len(v) and (v.max() > 2 ** 53 or v.min() < -2 ** 53):
                fixed = s.astype("string").fillna("").astype(object)
                notes.append("%s holds integers beyond 2^53, which a double cannot keep exactly; "
                             "it was stored as text" % c)
        elif pd.api.types.is_float_dtype(s):
            bad = ~np.isfinite(s.to_numpy(dtype=float, na_value=np.nan)) & s.notna().to_numpy()
            big = np.abs(s.to_numpy(dtype=float, na_value=0)) > STATA_MAX
            bad = bad | (big & np.isfinite(s.to_numpy(dtype=float, na_value=0)))
            if bad.any():
                fixed = s.mask(bad)
                notes.append("%s had %d infinite or out-of-range values that Stata cannot store; "
                             "they are missing in the deposit" % (c, int(bad.sum())))
        elif s.dtype == object:
            kinds = {type(v).__name__ for v in s.dropna()}
            odd = kinds - {"str", "int", "float", "bool", "date", "Timestamp", "datetime", "Decimal"}
            if odd:
                fixed = s.map(lambda v: "" if v is None or (isinstance(v, float) and np.isnan(v)) else str(v))
                notes.append("%s held %s values; they were stored as text" % (c, "/".join(sorted(odd))))
        if fixed is not None:
            if out is None:
                out = df.copy()
            out[c] = fixed
    return df if out is None else out


def from_dataframe(df, name="data", meta=None, source_file=""):
    notes = []
    attrs = dict(df.attrs)
    # work on a view without attrs: pandas deep-copies attrs on every column
    # access, which is slow when they hold the metadata of a wide file
    df = df.copy(deep=False)
    df.attrs = {}
    df = _clean_frame(df, notes)
    dd = attrs.get("datadeposit") if isinstance(attrs.get("datadeposit"), dict) else None
    if dd is not None and "variables" in dd:
        t = _from_deposit_frame(df, name, dd, source_file)
    else:
        t = _from_plain_frame(df, name, meta, source_file, attrs)
    t.notes = notes + t.notes
    return t


def _numeric_from_series(s, kind):
    if kind == "date":
        d = pd.to_datetime(s)
        x = np.full(len(s), np.nan)
        ok = d.notna().to_numpy()
        x[ok] = (d[ok].to_numpy().astype("datetime64[D]") - EPOCH_D).astype(np.int64)
        return x
    if kind == "datetime":
        d = pd.to_datetime(s)
        x = np.full(len(s), np.nan)
        ok = d.notna().to_numpy()
        x[ok] = (d[ok].to_numpy().astype("datetime64[ms]") - EPOCH_MS).astype(np.int64).astype(np.float64)
        return x
    return pd.to_numeric(s, errors="coerce").to_numpy(dtype=np.float64, na_value=np.nan)


def _from_deposit_frame(df, name, dd, source_file):
    """A DataFrame from deposit_use or a setup.py: rebuild the exact metadata."""
    variables = {v["name"]: v for v in dd["variables"]}
    rows = dd.get("char_rows", [])
    by_var, dta_chars = {}, []
    for r in rows:
        if r["variable"] == "_dta":
            if r["char"] != "datadeposit_source":
                dta_chars.append((r["char"], r["text"]))
        else:
            by_var.setdefault(r["variable"], []).append((r["char"], r["text"]))
    sets = {}
    for s, mapping in dd.get("value_labels", {}).items():
        sets[s] = [(k, v) for k, v in mapping.items()]
    extm = dd.get("extended_missing", {})
    pos = {lab: i for i, lab in enumerate(df.index)}
    notes = []
    try:
        n_loaded = int(dd.get("dataset_table", {}).get("n_obs", -1))
    except (TypeError, ValueError):
        n_loaded = -1
    newcols = [c for c in df.columns if c not in variables]
    new_sn = dict(zip(newcols, stata_names(newcols)))
    cols = []
    for c in df.columns:
        if c not in variables:
            col, extra = _infer_column(df[c], c, new_sn[c], None, None)
            sets.update(extra)
            cols.append(col)
            continue
        v = variables[c]
        kind, typ = v["kind"], v["stata_type"]
        s = df[c]
        if kind == "string":
            vals = _to_text(s)
            if typ != "strL":
                w = max([len(x.encode("utf-8")) for x in vals] + [1])
                if w > int(typ[3:]):
                    typ = "strL" if w > 2045 else "str%d" % w
            ext = None
        else:
            if isinstance(s.dtype, pd.CategoricalDtype):
                inv = {lab: k for k, lab in dd["variable_value_labels"].get(c, {}).items()}
                s = s.astype(object).map(lambda x: inv.get(x, x))
            ext = nan_tags(s.to_numpy()) if str(s.dtype) == "float64" else None
            x = _numeric_from_series(s, kind)
            if kind != "numeric" and c in extm:
                # dates cannot hold a code inside the value, so the positions
                # recorded at load time are used, but only while they still fit
                ext = np.zeros(len(x), dtype=np.int8)
                ok = len(df) == n_loaded
                for letter, idx in extm[c].items():
                    for lab in idx:
                        if lab in pos and np.isnan(x[pos[lab]]):
                            ext[pos[lab]] = ord(letter) - 96
                        else:
                            ok = False
                if not ok:
                    ext = None
                    notes.append("%s: rows changed since loading, so its extended missing codes "
                                 "(.a to .z) could not be placed and are plain missing" % c)
                elif not ext.any():
                    ext = None
            vals = x
            if kind == "numeric" and typ in ("byte", "int", "long"):
                it = _int_type(x)
                order = ["byte", "int", "long"]
                if it is None:
                    typ = "double"
                elif order.index(it) > order.index(typ):
                    typ = it
        cols.append(Column(c, v["stata_name"], typ, v["format"], v["label"], v["value_labels"], vals, ext,
                           by_var.get(v["stata_name"], [])))
    ds = dd.get("dataset_table", {})
    t = Table(name, cols, len(df), dd.get("file_label", ""), sets, dta_chars,
              [x for x in dd.get("sortedby", "").split() if x in {k.stata_name for k in cols}],
              source_file or ds.get("source_file", ""),
              question_char=ds.get("question_char") or None,
              provenance=dd.get("provenance", ""))
    t.notes = notes
    return t


def _infer_column(s, name, stata_name, label, labels):
    """A column with no stored Stata metadata."""
    if isinstance(s.dtype, pd.CategoricalDtype):
        cats = list(s.cat.categories)
        codes = s.cat.codes.to_numpy().astype(np.float64)
        codes[codes < 0] = np.nan
        codes = codes + 1
        typ = _int_type(codes) or "long"
        return (Column(name, stata_name, typ, _default_format(typ), label or "", stata_name, codes, None, []),
                {stata_name: [(i + 1, str(c)) for i, c in enumerate(cats)]})
    if pd.api.types.is_bool_dtype(s):
        x = s.astype("float64").to_numpy()
        return Column(name, stata_name, "byte", "%8.0g", label or "", "", x), {}
    if pd.api.types.is_datetime64_any_dtype(s):
        x = _numeric_from_series(s, "datetime")
        return Column(name, stata_name, "double", "%tc", label or "", "", x), {}
    if s.dtype == object and s.dropna().map(lambda v: type(v).__name__ == "date").all() and s.notna().any():
        x = _numeric_from_series(s, "date")
        return Column(name, stata_name, "long", "%td", label or "", "", x), {}
    if pd.api.types.is_numeric_dtype(s):
        ext = nan_tags(s.to_numpy()) if str(s.dtype) == "float64" else None
        x = pd.to_numeric(s, errors="coerce").to_numpy(dtype=np.float64, na_value=np.nan)
        if str(s.dtype) in ("float32", "Float32"):
            typ = "float"
        else:
            typ = _int_type(x) or "double"
        vl = stata_name if labels else ""
        return Column(name, stata_name, typ, _default_format(typ), label or "", vl, x, ext), {}
    vals = _to_text(s)
    typ = _str_type(vals)
    return Column(name, stata_name, typ, _default_format(typ), label or "", "", vals), {}


def _from_plain_frame(df, name, meta, source_file, attrs=None):
    attrs = attrs or {}
    labels = dict(attrs.get("column_names_to_labels", {}))
    vvl = dict(attrs.get("variable_value_labels", {}))
    v2l = dict(attrs.get("variable_to_label", {}))
    file_label = attrs.get("file_label", "") or ""
    if meta is not None:
        labels.update(getattr(meta, "column_names_to_labels", {}) or {})
        vvl.update(getattr(meta, "variable_value_labels", {}) or {})
        v2l.update(getattr(meta, "variable_to_label", {}) or {})
        file_label = getattr(meta, "file_label", None) or file_label
    names = list(df.columns)
    sn = dict(zip(names, stata_names(names)))
    cols, sets = [], {}
    for c in names:
        lab = labels.get(c) or ""
        col, extra = _infer_column(df[c], c, sn[c], lab, vvl.get(c))
        sets.update(extra)
        if c in vvl and col.kind == "numeric":
            setname = v2l.get(c) or sn[c]
            col.value_labels = setname
            entries = []
            for k, txt in vvl[c].items():
                try:
                    kv = float(k)
                except (TypeError, ValueError):
                    continue
                if kv == int(kv):
                    entries.append((int(kv), str(txt)))
            sets[setname] = entries
            if col.stata_type in ("byte", "int") and entries:
                hi = max(abs(e[0]) for e in entries)
                if hi > 32740:
                    col.stata_type, col.format = "long", "%12.0g"
                elif hi > 100 and col.stata_type == "byte":
                    col.stata_type, col.format = "int", "%8.0g"
        cols.append(col)
    return Table(name, cols, len(df), file_label, sets, [], [], source_file)


def read_any(path, name=None):
    """Load a data file into a Table, recognizing it by content rather than by name."""
    from .sniff import sniff
    ext = os.path.splitext(path)[1].lower()
    stem = name or stem_of(path)
    base = os.path.basename(path)
    sn = sniff(path)
    if not sn.is_data:
        raise ValueError("%s is not a data file: %s" % (base, sn.why))
    notes = []
    expect = {".dta": ("dta", "dta_old"), ".csv": ("delimited",), ".tsv": ("delimited",), ".txt": ("delimited",),
              ".xlsx": ("xlsx",), ".xls": ("xls", "xlsx"), ".sav": ("sav",), ".parquet": ("parquet",)}
    if ext in expect and sn.kind not in expect[ext]:
        notes.append("%s is really a %s file; read it as one" % (base, sn.kind))
    if sn.kind == "dta":
        t = from_dta(path, stem)
    elif sn.kind == "dta_old":
        df = pd.read_stata(path)
        notes.append("%s uses a Stata format older than 13, so its notes and characteristics were not read; "
                     "open it in Stata 14 or newer and save it again to keep them" % base)
        t = from_dataframe(df, stem, source_file=base)
    elif sn.kind in ("delimited", "gzip"):
        t = _read_delimited(path, stem, sn, notes)
    elif sn.kind in ("xlsx", "xls"):
        try:
            book = pd.read_excel(path, sheet_name=None)
        except ImportError as e:
            raise ValueError("%s is an Excel file; reading it needs openpyxl (pip install openpyxl): %s" % (base, e))
        first = next(iter(book))
        if len(book) > 1:
            notes.append("%s has %d sheets; only the first (%s) was deposited" % (base, len(book), first))
        t = from_dataframe(book[first], stem, source_file=base)
    elif sn.kind == "sav":
        try:
            import pyreadstat
        except ImportError:
            raise ValueError("%s is an SPSS file; reading it needs pyreadstat (pip install pyreadstat)" % base)
        df, meta = pyreadstat.read_sav(path)
        t = from_dataframe(df, stem, meta, base)
    elif sn.kind == "parquet":
        try:
            df = pd.read_parquet(path)
        except ImportError:
            raise ValueError("%s is a Parquet file; reading it needs pyarrow (pip install pyarrow)" % base)
        t = from_dataframe(df, stem, source_file=base)
    elif sn.kind == "rds":
        raise ValueError("%s is an R data file; deposit it from R with datadeposit()" % base)
    else:
        raise ValueError("%s: unsupported file type %s" % (base, sn.kind))
    t.notes = notes + t.notes
    return t


def _read_delimited(path, stem, sn, notes):
    import csv
    import gzip
    import io
    base = os.path.basename(path)
    if sn.kind == "gzip":
        from .sniff import sniff as _sniff
        import tempfile
        with gzip.open(path, "rb") as fh:
            inner = fh.read(65536)
        with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as tf:
            tf.write(inner)
        try:
            sn2 = _sniff(tf.name)
        finally:
            os.remove(tf.name)
        if sn2.kind != "delimited":
            raise ValueError("%s is compressed, and what it holds is not a delimited table: %s" % (base, sn2.why))
        sn = sn2
        opener = lambda: io.TextIOWrapper(gzip.open(path, "rb"), encoding=sn.encoding, newline="")
    else:
        opener = lambda: open(path, encoding=sn.encoding, newline="")
    with opener() as fh:
        header = next(csv.reader(fh, delimiter=sn.delim))
    names, seen = [], {}
    for k, h in enumerate(header):
        h = h.strip() or "v%d" % (k + 1)
        if h in seen:
            seen[h] += 1
            new = "%s_%d" % (h, seen[h])
            notes.append("%s repeats the column name %r; the repeat is named %r" % (base, h, new))
            h = new
        else:
            seen[h] = 1
        names.append(h)
    if sn.encoding == "latin-1":
        notes.append("%s is not UTF-8; it was read as Latin-1 (Windows-1252) and the deposit is UTF-8" % base)
    if sn.delim != ",":
        notes.append("%s is delimited by %r; the deposit's csv uses commas" % (base, sn.delim))
    if sn.decimal == ",":
        notes.append("%s writes decimals with a comma; numbers were read that way" % base)
    try:
        df = pd.read_csv(path, sep=sn.delim, encoding=sn.encoding, header=0, names=names, dtype=str,
                         index_col=False, keep_default_na=False, quotechar='"',
                         compression="gzip" if path.lower().endswith(".gz") or sn.kind == "gzip" else None)
    except (pd.errors.ParserError, ValueError) as e:
        raise ValueError("%s could not be read as a %r-delimited table: %s" % (base, sn.delim, str(e).strip()))
    df = typed_columns(df, sn.decimal, base, notes)
    return from_dataframe(df, stem, source_file=base)


def typed_columns(df, decimal=".", base="", notes=None):
    """Read text columns as numbers only when every value is a number.

    A column with a value such as 01234 (a ZIP code, an ID) stays text, so
    leading zeros are never lost; the same rule is used in R and Stata.
    """
    out = {}
    kept, natok = [], []
    for c in df.columns:
        s = df[c].astype(object).where(df[c].notna(), "").astype(str)
        t = s.str.strip()
        nonempty = ~t.isin(MISSING_TOKENS)
        if not nonempty.any():
            out[c] = s
            continue
        u = t.str.replace(",", ".", regex=False) if decimal == "," else t
        # Python's float() is exact; pandas before version 3 is not when it converts text
        num = pd.Series([float(x) if (ok and NUMBER.match(x)) else np.nan
                         for x, ok in zip(u.tolist(), nonempty.tolist())], index=u.index, dtype="float64")
        num = num.where(np.isfinite(num.to_numpy(dtype=float, na_value=np.nan)))
        allnum = bool(num[nonempty].notna().all())
        lead0 = bool(t[nonempty].str.match(r"^-?0[0-9]").any())
        if allnum and not lead0:
            out[c] = num.astype("float64")
            if (t.isin(MISSING_TOKENS) & (t != "")).any():
                natok.append(c)
        else:
            out[c] = s
            if lead0 and allnum:
                kept.append(c)
    if kept and notes is not None:
        notes.append("%s: %s kept as text because values start with 0 (for example ZIP codes or IDs)"
                     % (base, ", ".join(kept)))
    if natok and notes is not None:
        notes.append("%s: NA, N/A, NaN, null, or . read as missing in the numeric column(s) %s"
                     % (base, ", ".join(natok)))
    return pd.DataFrame(out, index=df.index)
