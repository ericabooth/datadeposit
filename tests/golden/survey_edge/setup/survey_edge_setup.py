"""datadeposit setup file for Python (deposit spec 1.0).

Rebuilds dataset survey_edge from data/survey_edge.csv and the tables in metadata/.

From Python:
    import runpy
    df = runpy.run_path("<deposit>/setup/survey_edge_setup.py")["load"]()
    df = runpy.run_path("<deposit>/setup/survey_edge_setup.py")["load"](categoricals=True)
From a shell:
    python setup/survey_edge_setup.py [--root DIR] [--save-pickle FILE] [--save-parquet FILE]

Needs pandas and the standard library only. Labels and other metadata land in
df.attrs["datadeposit"]; the pyreadstat-style names (column_names_to_labels,
variable_value_labels, value_labels, variable_to_label) are also set at the
top level of df.attrs. Every label, value label, note, and characteristic
comes from the metadata tables, so you can edit those tables and rerun.
"""

import csv
import os
import re
import sys

try:
    import pandas as pd
except ImportError:  # pragma: no cover - depends on the machine
    sys.exit("setup: this script needs pandas. Install it with:  python -m pip install pandas\n"
             "       (or: conda install pandas). Then run this file again.")

DATASET = "survey_edge"
SPEC = "1.0"
_TAG = re.compile(r"^\.[a-z]$")


def _here():
    try:
        return os.path.dirname(os.path.abspath(__file__))
    except NameError:
        return os.getcwd()


def _find_root(root=None):
    def ok(d):
        return os.path.exists(os.path.join(d, "metadata", DATASET + "_variables.csv"))

    if root is not None:
        if not ok(root):
            raise FileNotFoundError("setup: no metadata/%s_variables.csv under %s" % (DATASET, root))
        return root
    for cand in (os.path.dirname(_here()), os.getcwd(), os.path.dirname(os.getcwd())):
        if ok(cand):
            return cand
    raise FileNotFoundError("setup: cannot find metadata/%s_variables.csv; pass root=" % DATASET)


def _table(root, tab):
    path = os.path.join(root, "metadata", "%s_%s.csv" % (DATASET, tab))
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _value(v):
    return v if _TAG.match(v) else int(v) if re.match(r"^-?\d+$", v) else float(v)


def load(root=None, categoricals=False):
    """Return the dataset as a pandas DataFrame with its metadata in df.attrs."""
    root = _find_root(root)
    variables = _table(root, "variables")
    vlabels = _table(root, "valuelabels")
    chars = _table(root, "chars")
    dataset = {r["key"]: r["value"] for r in _table(root, "dataset")}

    dtypes, na_values = {}, {}
    for v in variables:
        if v["kind"] == "numeric" and v["extended_missing"] != "1":
            dtypes[v["name"]] = "float64"
            na_values[v["name"]] = [""]
        else:
            dtypes[v["name"]] = str
    path = os.path.join(root, "data", DATASET + ".csv")
    # pandas 3 parses every number exactly by default; older pandas needs
    # float_precision="round_trip" to do so
    exact = {} if int(pd.__version__.split(".")[0]) >= 3 else {"float_precision": "round_trip"}
    df = pd.read_csv(path, dtype=dtypes, keep_default_na=False, na_values=na_values,
                     encoding="utf-8", sep=",", quotechar='"', doublequote=True, **exact)
    if df.shape[1] != len(variables):
        raise ValueError("setup: %s has %d columns but the variables table lists %d"
                         % (path, df.shape[1], len(variables)))
    df.columns = [v["name"] for v in variables]

    sets = {}
    for r in vlabels:
        sets.setdefault(r["set"], {})[_value(r["value"])] = r["label"]

    by_var = {}
    for r in chars:
        by_var.setdefault(r["variable"], []).append(r)

    def split_chars(var):
        notes, other = [], {}
        for r in by_var.get(var, []):
            m = re.match(r"^note(\d+)$", r["char"])
            if m:
                if m.group(1) != "0":
                    notes.append((int(m.group(1)), r["text"]))
            elif r["char"] not in ("datadeposit_label", "datadeposit_name"):
                other[r["char"]] = r["text"]
        return [t for _, t in sorted(notes)], other

    qchar = dataset.get("question_char", "")
    meta = {"dataset": DATASET, "spec": SPEC, "root": os.path.abspath(root),
            "file_label": dataset.get("label", ""), "sortedby": dataset.get("sortedby", ""),
            "column_labels": {}, "variable_value_labels": {}, "value_labels": sets,
            "variable_to_label": {}, "formats": {}, "stata_types": {}, "notes": {},
            "chars": {}, "questions": {}, "extended_missing": {}, "variables": variables,
            "char_rows": chars, "dataset_table": dataset}

    for v in variables:
        name, kind = v["name"], v["kind"]
        col = df[name]
        if kind != "string" and not pd.api.types.is_numeric_dtype(col):
            s = col.astype(str)
            tags = s.str.match(r"^\.[a-z]$")
            if tags.any():
                ext = {}
                for idx, tok in s[tags].items():
                    ext.setdefault(tok[1], []).append(int(idx))
                meta["extended_missing"][name] = ext
            s = s.where(~tags, "")
            if kind == "numeric":
                num = pd.to_numeric(s.where(s != "", None), errors="coerce")
                bad = num.isna() & (s != "")
                if bad.any():
                    raise ValueError("setup: %s has non-numeric values, first: %r" % (name, s[bad].iloc[0]))
                df[name] = num.astype("float64")
            elif kind == "date":
                df[name] = pd.to_datetime(s.where(s != "", None), format="%Y-%m-%d", errors="raise")
            elif kind == "datetime":
                df[name] = pd.to_datetime(s.where(s != "", None), format="%Y-%m-%d %H:%M:%S.%f", errors="raise")
        if kind == "numeric" and v["stata_type"] == "float":
            # Stata floats are float32; the csv text rounds back to the same float32
            df[name] = df[name].astype("float32").astype("float64")
        if v["label"]:
            meta["column_labels"][name] = v["label"]
        meta["formats"][name] = v["format"]
        meta["stata_types"][name] = v["stata_type"]
        if v["value_labels"]:
            meta["variable_to_label"][name] = v["value_labels"]
            meta["variable_value_labels"][name] = dict(sets.get(v["value_labels"], {}))
        notes, other = split_chars(v["stata_name"])
        if notes:
            meta["notes"][name] = notes
        if other:
            meta["chars"][name] = other
            if qchar and qchar in other:
                meta["questions"][name] = other[qchar]
        if categoricals and v["value_labels"] and kind == "numeric":
            labels = {k: t for k, t in sets.get(v["value_labels"], {}).items() if not isinstance(k, str)}

            def lab(c, labels=labels):
                if pd.isna(c):
                    return None
                if float(c).is_integer() and int(c) in labels:
                    return labels[int(c)]
                return "%g" % c

            mapped = df[name].map(lab)
            cats = list(dict.fromkeys(list(labels.values()) + list(mapped.dropna().unique())))
            df[name] = pd.Categorical(mapped, categories=cats)

    notes, other = split_chars("_dta")
    meta["notes"]["_dta"] = notes
    meta["chars"]["_dta"] = other

    df.attrs["datadeposit"] = meta
    df.attrs["column_names_to_labels"] = meta["column_labels"]
    df.attrs["variable_value_labels"] = meta["variable_value_labels"]
    df.attrs["value_labels"] = meta["value_labels"]
    df.attrs["variable_to_label"] = meta["variable_to_label"]
    df.attrs["file_label"] = meta["file_label"]
    print("setup: built %s (%d obs, %d vars, %d variable labels, %d value labels, %d characteristics)"
          % (DATASET, df.shape[0], df.shape[1], len(meta["column_labels"]), len(vlabels), len(chars)),
          file=sys.stderr)
    return df


def _main(argv):
    def arg(flag):
        return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None

    df = load(root=arg("--root"))
    out = arg("--save-pickle")
    if out:
        df.to_pickle(out)
    out = arg("--save-parquet")
    if out:
        df.to_parquet(out)
    return df


if __name__ == "__main__":
    _main(sys.argv[1:])
