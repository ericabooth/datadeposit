"""The datadeposit table model and every file writer.

A Table holds one dataset in Stata terms: storage types, display formats,
labels, value label sets, characteristics, and values (numbers in Stata units,
so dates are days since 1960 and datetimes milliseconds since 1960). Every
writer here mirrors the Mata writer in datadeposit.ado line for line, so the
same data produce the same metadata tables, codebook, and DDI file whether a
deposit is made from Stata, R, or Python.
"""

import datetime as _dt
import json
import math
import os
import re

import numpy as np

SPEC = "1.0"
EPOCH_D = np.datetime64("1960-01-01", "D")
EPOCH_MS = np.datetime64("1960-01-01T00:00:00.000", "ms")
QUESTION_CHARS = ("question", "question_text", "qtext", "item", "item_text", "wording", "prompt", "Question")
NOTE = re.compile(r"^note[0-9]+$")


class Column:
    __slots__ = ("name", "stata_name", "stata_type", "format", "label", "value_labels", "values", "ext", "chars")

    def __init__(self, name, stata_name, stata_type, fmt, label, value_labels, values, ext=None, chars=None):
        self.name = name
        self.stata_name = stata_name
        self.stata_type = stata_type
        self.format = fmt
        self.label = label or ""
        self.value_labels = value_labels or ""
        self.values = values
        self.ext = ext
        self.chars = list(chars or [])

    @property
    def kind(self):
        return kind_of(self.stata_type, self.format)


class Table:
    def __init__(self, name, columns, nobs, label="", value_label_sets=None, dta_chars=None,
                 sortedby=None, source_file="", question_char=None, provenance=""):
        self.name = name
        self.columns = columns
        self.nobs = nobs
        self.label = label or ""
        self.value_label_sets = dict(value_label_sets or {})
        self.dta_chars = list(dta_chars or [])
        self.sortedby = list(sortedby or [])
        self.source_file = source_file
        self.question_char = question_char
        self.provenance = provenance
        self.notes = []

    def used_sets(self):
        """Sets Stata's save keeps: attached ones and those named by label languages."""
        used = set()
        for c in self.columns:
            if c.value_labels:
                used.add(c.value_labels)
            for n, t in c.chars:
                if n.startswith("_lang_l_"):
                    used.add(t)
        return [s for s in sorted(self.value_label_sets) if s in used]

    def stata_chars(self):
        """Characteristics as Stata stores them, including datadeposit_label for long labels."""
        rows = [("_dta", n, t) for n, t in self.dta_chars]
        for c in self.columns:
            rows += [(c.stata_name, n, t) for n, t in c.chars]
            if len(c.label) > 80:
                rows.append((c.stata_name, "datadeposit_label", c.label))
            if c.name != c.stata_name:
                rows.append((c.stata_name, "datadeposit_name", c.name))
        return rows

    def find_question_char(self):
        if self.question_char is not None:
            return self.question_char
        for cand in QUESTION_CHARS:
            for c in self.columns:
                if any(n == cand for n, _ in c.chars):
                    return cand
        return ""


def kind_of(stata_type, fmt):
    if stata_type.startswith("str"):
        return "string"
    f = fmt.replace("%-", "%", 1)
    if f.startswith("%td") or f.startswith("%d"):
        return "date"
    if f.startswith("%tc") or f.startswith("%tC"):
        return "datetime"
    return "numeric"


# ----------------------------------------------------------------------------
# number and text formatting (identical rules in Stata, R, and Python)
# ----------------------------------------------------------------------------

def fmtnum(x):
    """Integers below 1e15 in full; everything else as C printf %.10g."""
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return ""
    x = float(x)
    if x == 0:
        return "0"
    if x == math.floor(x) and abs(x) < 1e15:
        return "%d" % x
    return "%.10g" % x


def vfmt(v):
    if isinstance(v, str):
        return v
    if float(v) == math.floor(float(v)):
        return "%d" % v
    return fmtnum(v)


def ext_token(k):
    return "." + chr(96 + int(k))


def iso_date(days):
    return str(EPOCH_D + np.timedelta64(int(days), "D"))


def iso_datetime(ms):
    s = np.datetime_as_string(EPOCH_MS + np.timedelta64(int(round(ms)), "ms"), unit="ms")
    return s.replace("T", " ")


def qt(s):
    return '"' + s.replace('"', '""') + '"'


def write_csv(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        for r in rows:
            fh.write(",".join(qt(x) for x in r) + "\n")


def read_csv(path):
    import csv
    with open(path, encoding="utf-8", newline="") as fh:
        return list(csv.reader(fh))


def table_dicts(path):
    rows = read_csv(path)
    if not rows:
        return []
    head = rows[0]
    return [dict(zip(head, r)) for r in rows[1:]]


def spit(path, text):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def meta_path(root, ds, tab):
    return os.path.join(root, "metadata", "%s_%s.csv" % (ds, tab))


def mdcell(s):
    s = s.replace("\r\n", "\n").replace("|", "\\|")
    return s.replace("\n", "<br>")


def mdquote(s):
    s = s.replace("\r\n", "\n")
    return "> " + s.replace("\n", "\n> ")


def xml(s):
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    return "".join(ch for ch in s if ord(ch) >= 32 or ch in "\t\n\r")


def js(s):
    out = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r")
    out = out.replace("\t", "\\t").replace("\b", "\\b").replace("\f", "\\f")
    out = "".join("\\u%04x" % ord(ch) if ord(ch) < 32 else ch for ch in out)
    return '"' + out + '"'


def now_iso():
    return _dt.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


# ----------------------------------------------------------------------------
# metadata tables
# ----------------------------------------------------------------------------

def write_metadata(root, t):
    V = [["position", "name", "stata_name", "stata_type", "kind", "format", "label", "value_labels",
          "extended_missing"]]
    for k, c in enumerate(t.columns, 1):
        ext = "1" if (c.kind != "string" and c.ext is not None and (np.asarray(c.ext) > 0).any()) else "0"
        V.append([str(k), c.name, c.stata_name, c.stata_type, c.kind, c.format, c.label, c.value_labels, ext])
    write_csv(meta_path(root, t.name, "variables"), V)

    L = [["set", "value", "label"]]
    for s in t.used_sets():
        for v, lab in sort_entries(t.value_label_sets[s]):
            L.append([s, vfmt(v), lab])
    write_csv(meta_path(root, t.name, "valuelabels"), L)

    C = [["variable", "char", "text"]]
    for n, txt in sorted(t.dta_chars):
        if n != "datadeposit_source":
            C.append(["_dta", n, txt])
    for c in t.columns:
        for n, txt in sorted(c.chars):
            if n not in ("datadeposit_label", "datadeposit_name"):
                C.append([c.stata_name, n, txt])
    write_csv(meta_path(root, t.name, "chars"), C)

    D = [["key", "value"], ["dataset", t.name], ["label", t.label], ["n_obs", str(t.nobs)],
         ["n_vars", str(len(t.columns))], ["sortedby", " ".join(t.sortedby)],
         ["question_char", t.find_question_char()], ["source_file", t.source_file], ["spec_version", SPEC]]
    write_csv(meta_path(root, t.name, "dataset"), D)


def sort_entries(entries):
    def key(e):
        v = e[0]
        return (1, ord(v[1]) if len(v) > 1 else 0) if isinstance(v, str) else (0, v)
    return sorted(entries, key=key)


def write_stats(root, t):
    S = [["variable", "kind", "n_valid", "n_missing", "n_extended", "min", "max", "mean", "sd"]]
    F = [["variable", "value", "label", "count"]]
    N = t.nobs
    for c in t.columns:
        kind = c.kind
        if kind == "string":
            valid = int(sum(1 for s in c.values if s != ""))
            S.append([c.stata_name, kind, str(valid), str(N - valid), "0", "", "", "", ""])
            continue
        x = np.asarray(c.values, dtype=np.float64)
        ext = c.ext if c.ext is not None else np.zeros(N, dtype=np.int8)
        isnan = np.isnan(x)
        n_ext = int(((ext > 0) & isnan).sum())
        sys_ = int(isnan.sum()) - n_ext
        xv = x[~isnan]
        valid = len(xv)
        mn = mx = me = sd = ""
        if valid:
            if kind == "date":
                mn, mx = iso_date(xv.min()), iso_date(xv.max())
            elif kind == "datetime":
                mn, mx = iso_datetime(xv.min()), iso_datetime(xv.max())
            else:
                mn, mx = fmtnum(xv.min()), fmtnum(xv.max())
                me = fmtnum(float(np.mean(xv)))
                if valid > 1:
                    sd = fmtnum(float(np.std(xv, ddof=1)))
        S.append([c.stata_name, kind, str(valid), str(sys_), str(n_ext), mn, mx, me, sd])
        if not c.value_labels or kind != "numeric":
            continue
        entries = t.value_label_sets.get(c.value_labels, [])
        labmap = {}
        for v, lab in entries:
            labmap[v] = lab
        obs = {}
        uniq, counts = np.unique(xv, return_counts=True)
        for u, n in zip(uniq, counts):
            obs[float(u)] = int(n)
        for k in range(1, 27):
            n = int(((ext == k) & isnan).sum())
            if n:
                obs[ext_token(k)] = n
        keys = set()
        for v, _ in entries:
            keys.add(v if isinstance(v, str) else float(v))
        keys |= set(obs)
        for v in sort_keys(keys):
            lab = labmap.get(v if isinstance(v, str) else (int(v) if v == int(v) else v), "")
            if not isinstance(v, str) and v == int(v):
                lab = labmap.get(int(v), lab)
            F.append([c.stata_name, vfmt(v), lab, str(obs.get(v, 0))])
        if sys_:
            F.append([c.stata_name, ".", "", str(sys_)])
    write_csv(meta_path(root, t.name, "summary"), S)
    write_csv(meta_path(root, t.name, "frequencies"), F)


def sort_keys(keys):
    nums = sorted(k for k in keys if not isinstance(k, str))
    exts = sorted(k for k in keys if isinstance(k, str))
    return nums + exts


# ----------------------------------------------------------------------------
# data csv
# ----------------------------------------------------------------------------

def _num_strings(c):
    x = np.asarray(c.values, dtype=np.float64)
    n = len(x)
    out = np.empty(n, dtype=object)
    isnan = np.isnan(x)
    kind = c.kind
    ok = ~isnan
    if kind == "date":
        d = (EPOCH_D + x[ok].astype(np.int64).astype("timedelta64[D]")).astype(str)
        out[ok] = d
    elif kind == "datetime":
        ms = np.round(x[ok]).astype(np.int64).astype("timedelta64[ms]")
        s = np.datetime_as_string(EPOCH_MS + ms, unit="ms")
        out[ok] = np.char.replace(s.astype(str), "T", " ")
    elif c.stata_type in ("byte", "int", "long"):
        out[ok] = [str(int(v)) for v in x[ok]]
    elif c.stata_type == "float":
        out[ok] = ["%.9g" % v for v in x[ok].astype(np.float32).astype(np.float64)]
    else:
        out[ok] = ["%.17g" % v for v in x[ok]]
    out[isnan] = ""
    if c.ext is not None:
        ext = np.asarray(c.ext)
        for k in np.unique(ext[(ext > 0) & isnan]):
            out[(ext == k) & isnan] = ext_token(k)
    return out


def _header_field(name):
    if any(ch in name for ch in ',"\n\r') or name != name.strip():
        return qt(name)
    return name


def write_data_csv(path, t, chunk=100000):
    cols = []
    for c in t.columns:
        if c.kind == "string":
            cols.append(np.array([qt(s) for s in c.values], dtype=object))
        else:
            cols.append(_num_strings(c))
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(",".join(_header_field(c.name) for c in t.columns) + "\n")
        for start in range(0, t.nobs, chunk):
            stop = min(start + chunk, t.nobs)
            lines = [",".join(col[r] for col in cols) for r in range(start, stop)]
            if lines:
                fh.write("\n".join(lines) + "\n")


# ----------------------------------------------------------------------------
# codebook markdown, DDI, datapackage, README, MANIFEST
# ----------------------------------------------------------------------------

def _md_chars(v, chars, qchar):
    notes = sorted(((int(r["char"][4:]), r["text"]) for r in chars
                    if r["variable"] == v and NOTE.match(r["char"]) and r["char"] != "note0"))
    out = ""
    if notes:
        out = "**Notes:**\n\n" + "".join("%d. %s\n" % (j, mdcell(t)) for j, (_, t) in enumerate(notes, 1)) + "\n"
    other = ""
    for r in chars:
        if r["variable"] != v or NOTE.match(r["char"]) or r["char"] == qchar:
            continue
        if not other:
            other = "**Characteristics:**\n\n"
        other += "- %s: %s\n" % (r["char"], mdcell(r["text"]))
    if other:
        other += "\n"
    return out + other


def write_codebook_md(root, ds):
    V = table_dicts(meta_path(root, ds, "variables"))
    L = table_dicts(meta_path(root, ds, "valuelabels"))
    C = table_dicts(meta_path(root, ds, "chars"))
    D = read_csv(meta_path(root, ds, "dataset"))[1:]
    S = table_dicts(meta_path(root, ds, "summary")) if os.path.exists(meta_path(root, ds, "summary")) else None
    F = table_dicts(meta_path(root, ds, "frequencies")) if os.path.exists(meta_path(root, ds, "frequencies")) else None
    dd = dict((k, v) for k, v in D)
    dlab, qchar = dd.get("label", ""), dd.get("question_char", "")
    out = "# Codebook: %s\n\n" % ds
    if dlab:
        out += dlab + "\n\n"
    out += "| Item | Value |\n|---|---|\n"
    for k, v in D:
        if k in ("dataset", "label", "spec_version"):
            continue
        out += "| %s | %s |\n" % (k, mdcell(v))
    out += "\n"
    t = _md_chars("_dta", C, "")
    if t:
        out += "## Dataset notes and characteristics\n\n" + t
    out += "## Variables\n\n| # | Name | Label | Type | Value labels |\n|---|---|---|---|---|\n"
    for k, v in enumerate(V, 1):
        out += "| %d | %s | %s | %s | %s |\n" % (k, v["stata_name"], mdcell(v["label"]), v["stata_type"], v["value_labels"])
    out += "\n"
    for v in V:
        nm = v["stata_name"]
        out += "### %s\n\n" % nm
        if v["label"]:
            out += "**Label:** %s\n\n" % mdcell(v["label"])
        if qchar:
            for r in C:
                if r["variable"] == nm and r["char"] == qchar:
                    out += "**Question text:**\n\n" + mdquote(r["text"]) + "\n\n"
        out += "**Type:** %s (%s), format %s\n\n" % (v["stata_type"], v["kind"], v["format"])
        if S is not None:
            for s in S:
                if s["variable"] != nm:
                    continue
                t = "**Values:** %s valid, %s%s" % (s["n_valid"], s["n_missing"],
                                                    " empty" if v["kind"] == "string" else " missing")
                if s["n_extended"] != "0":
                    t += ", %s extended missing" % s["n_extended"]
                if s["min"]:
                    t += "; min %s, max %s" % (s["min"], s["max"])
                if s["mean"]:
                    t += ", mean %s" % s["mean"]
                if s["sd"]:
                    t += ", sd %s" % s["sd"]
                out += t + "\n\n"
        if v["value_labels"]:
            out += "**Value labels** (%s):\n\n" % v["value_labels"]
            if F is not None:
                out += "| Value | Label | Count |\n|---|---|---|\n"
                for f in F:
                    if f["variable"] == nm:
                        out += "| %s | %s | %s |\n" % (f["value"], mdcell(f["label"]), f["count"])
            else:
                out += "| Value | Label |\n|---|---|\n"
                for r in L:
                    if r["set"] == v["value_labels"]:
                        out += "| %s | %s |\n" % (r["value"], mdcell(r["label"]))
            out += "\n"
        out += _md_chars(nm, C, qchar)
    spit(os.path.join(root, "codebook", ds + "_codebook.md"), out)


def _ddistat(typ, v):
    return '      <sumStat type="%s">%s</sumStat>\n' % (typ, v) if v != "" else ""


def write_ddi(root, ds):
    V = table_dicts(meta_path(root, ds, "variables"))
    L = table_dicts(meta_path(root, ds, "valuelabels"))
    C = table_dicts(meta_path(root, ds, "chars"))
    dd = dict(read_csv(meta_path(root, ds, "dataset"))[1:])
    S = table_dicts(meta_path(root, ds, "summary")) if os.path.exists(meta_path(root, ds, "summary")) else None
    F = table_dicts(meta_path(root, ds, "frequencies")) if os.path.exists(meta_path(root, ds, "frequencies")) else None
    qchar, dlab = dd.get("question_char", ""), dd.get("label", "")
    out = '<?xml version="1.0" encoding="UTF-8"?>\n<codeBook xmlns="ddi:codebook:2_5" version="2.5">\n'
    out += "  <stdyDscr>\n    <citation>\n      <titlStmt>\n        <titl>%s</titl>\n" % xml(dlab or ds)
    out += "      </titlStmt>\n    </citation>\n  </stdyDscr>\n"
    out += '  <fileDscr ID="F1">\n    <fileTxt>\n      <fileName>%s.csv</fileName>\n' % xml(ds)
    out += "      <dimensns>\n        <caseQnty>%s</caseQnty>\n        <varQnty>%s</varQnty>\n      </dimensns>\n" % (
        dd.get("n_obs", ""), dd.get("n_vars", ""))
    out += "      <fileType>text/csv</fileType>\n    </fileTxt>\n  </fileDscr>\n  <dataDscr>\n"
    for k, v in enumerate(V, 1):
        nm = v["stata_name"]
        t = '    <var ID="V%d" name="%s" files="F1"' % (k, xml(nm))
        if v["kind"] == "numeric":
            t += ' intrvl="%s"' % ("discrete" if v["value_labels"] else "contin")
        out += t + ">\n"
        if v["label"]:
            out += "      <labl>%s</labl>\n" % xml(v["label"])
        if qchar:
            for r in C:
                if r["variable"] == nm and r["char"] == qchar:
                    out += "      <qstn>\n        <qstnLit>%s</qstnLit>\n      </qstn>\n" % xml(r["text"])
        if S is not None:
            for s in S:
                if s["variable"] != nm:
                    continue
                out += _ddistat("vald", s["n_valid"])
                out += _ddistat("invd", str(int(s["n_missing"]) + int(s["n_extended"])))
                if v["kind"] == "numeric":
                    for a, b in (("min", "min"), ("max", "max"), ("mean", "mean"), ("stdev", "sd")):
                        out += _ddistat(a, s[b])
        if v["value_labels"]:
            src = [f for f in F if f["variable"] == nm] if F is not None else \
                [{"value": r["value"], "label": r["label"]} for r in L if r["set"] == v["value_labels"]]
            for f in src:
                out += "      <catgry%s>\n" % (' missing="Y"' if f["value"].startswith(".") else "")
                out += "        <catValu>%s</catValu>\n" % xml(f["value"])
                if F is None or f["label"]:
                    out += "        <labl>%s</labl>\n" % xml(f["label"])
                if F is not None:
                    out += '        <catStat type="freq">%s</catStat>\n' % f["count"]
                out += "      </catgry>\n"
        out += '      <varFormat type="%s" schema="other" formatname="%s"/>\n' % (
            "character" if v["kind"] == "string" else "numeric", xml(v["format"]))
        for r in C:
            if r["variable"] == nm and NOTE.match(r["char"]) and r["char"] != "note0":
                out += "      <notes>%s</notes>\n" % xml(r["text"])
        out += "    </var>\n"
    out += "  </dataDscr>\n</codeBook>\n"
    spit(os.path.join(root, "codebook", ds + "_ddi.xml"), out)


def _clean(s):
    s = re.sub(r"[^A-Za-z0-9_-]", "_", s.strip())
    return s or "data"


def write_datapackage(root, stems, info):
    out = "{\n"
    out += '  "name": %s,\n' % js(_clean(os.path.basename(os.path.normpath(root))).lower())
    if info["title"]:
        out += '  "title": %s,\n' % js(info["title"])
    if info["description"]:
        out += '  "description": %s,\n' % js(info["description"])
    out += '  "version": %s,\n' % js(info["version"])
    out += '  "created": %s,\n' % js(now_iso())
    if info["authors"]:
        auth = info["authors"].split(";")
        out += '  "contributors": [\n'
        for i, a in enumerate(auth):
            out += '    {"title": %s, "roles": ["author"]}%s\n' % (js(a.strip()), "," if i < len(auth) - 1 else "")
        out += "  ],\n"
    if info["license"]:
        out += '  "licenses": [{"name": %s}],\n' % js(info["license"])
    out += '  "resources": [\n'
    for d, ds in enumerate(stems):
        V = table_dicts(meta_path(root, ds, "variables"))
        L = table_dicts(meta_path(root, ds, "valuelabels"))
        C = table_dicts(meta_path(root, ds, "chars"))
        dd = dict(read_csv(meta_path(root, ds, "dataset"))[1:])
        qchar, dlab = dd.get("question_char", ""), dd.get("label", "")
        out += "    {\n"
        out += '      "name": %s,\n      "path": %s,\n' % (js(ds.lower()), js("data/%s.csv" % ds))
        if dlab:
            out += '      "title": %s,\n' % js(dlab)
        out += '      "format": "csv",\n      "mediatype": "text/csv",\n      "encoding": "utf-8",\n'
        out += '      "schema": {\n        "fields": [\n'
        for k, v in enumerate(V):
            if v["kind"] in ("string", "date", "datetime"):
                ftype = v["kind"]
            elif v["stata_type"] in ("byte", "int", "long"):
                ftype = "integer"
            else:
                ftype = "number"
            out += "          {\n"
            out += '            "name": %s,\n            "type": %s,\n' % (js(v["name"]), js(ftype))
            if v["label"]:
                out += '            "title": %s,\n' % js(v["label"])
            if qchar:
                for r in C:
                    if r["variable"] == v["stata_name"] and r["char"] == qchar:
                        out += '            "description": %s,\n' % js(r["text"])
            if v["value_labels"]:
                cats = ['{"value": %s, "label": %s}' % (r["value"], js(r["label"])) for r in L
                        if r["set"] == v["value_labels"] and not r["value"].startswith(".")]
                if cats:
                    out += '            "categories": [%s],\n' % ", ".join(cats)
            miss = ['{"value": "", "label": "missing"}']
            if v["value_labels"]:
                miss += ['{"value": %s, "label": %s}' % (js(r["value"]), js(r["label"])) for r in L
                         if r["set"] == v["value_labels"] and r["value"].startswith(".")]
            out += '            "missingValues": [%s],\n' % ", ".join(miss)
            out += '            "stata": {"name": %s, "type": %s, "format": %s, "valueLabels": %s}\n' % (
                js(v["stata_name"]), js(v["stata_type"]), js(v["format"]), js(v["value_labels"]))
            out += "          }%s\n" % ("," if k < len(V) - 1 else "")
        out += "        ]\n      }\n    }%s\n" % ("," if d < len(stems) - 1 else "")
    out += "  ]\n}\n"
    spit(os.path.join(root, "datapackage.json"), out)


WHAT = [
    (r"^data/.*\.csv$", "the data, plain text (codes, not labels)"),
    (r"^data/.*\.dta$", "the data for Stata"),
    (r"^data/.*\.rds$", "the data for R (base data.frame with attributes)"),
    (r"^data/.*\.xlsx$", "the data for Excel (codes sheet and labels sheet)"),
    (r"^data/.*\.sav$", "the data for SPSS"),
    (r"_variables\.csv$", "one row per variable: type, format, label, value label set"),
    (r"_valuelabels\.csv$", "every value label"),
    (r"_chars\.csv$", "notes and characteristics, including item text"),
    (r"_dataset\.csv$", "dataset label, size, sort order"),
    (r"_summary\.csv$", "statistics for each variable"),
    (r"_frequencies\.csv$", "counts for every labelled variable"),
    (r"_codebook\.md$", "codebook to read"),
    (r"_codebook\.xlsx$", "codebook as Excel sheets"),
    (r"_ddi\.xml$", "DDI Codebook 2.5 for data archives"),
    (r"_setup\.do$", "rebuilds the data in Stata"),
    (r"_setup\.R$", "rebuilds the data in R"),
    (r"_setup\.py$", "rebuilds the data in Python"),
    (r"^datapackage\.json$", "Frictionless Data Package description"),
    (r"^docs/", "included document"),
]


def what(f):
    for pat, txt in WHAT:
        if re.search(pat, f):
            return txt
    return ""


def list_files(root):
    out = [f for f in os.listdir(root) if os.path.isfile(os.path.join(root, f))]
    for sub in ("codebook", "data", "docs", "metadata", "setup"):
        d = os.path.join(root, sub)
        if os.path.isdir(d):
            out += [sub + "/" + f for f in os.listdir(d) if os.path.isfile(os.path.join(d, f))]
    out = [f for f in out if f != "MANIFEST.json" and not os.path.basename(f).startswith(".")]
    return sorted(out, key=lambda s: s.encode("utf-8"))


def write_readme(root, stems, info):
    fe = "```"
    fmts = info["formats"]
    tit = info["title"] or "Data deposit: " + ", ".join(stems)
    out = "# %s\n\n" % tit
    if info["description"]:
        out += info["description"] + "\n\n"
    out += ("This folder is an archive-ready data deposit. It holds the data, a codebook, "
            "and setup scripts that rebuild the labelled data in Stata, R, and Python from "
            "the plain-text csv. It was written by datadeposit %s in %s on %s.\n\n"
            % (info["package_version"], info["software"], now_iso()))
    out += "| Item | Value |\n|---|---|\n"
    if info["authors"]:
        out += "| Authors | %s |\n" % mdcell(info["authors"])
    out += "| Version | %s |\n" % mdcell(info["version"])
    out += "| Profile | %s |\n" % info["profile"]
    if info["license"]:
        out += "| License | %s |\n" % mdcell(info["license"])
    if info["changes"]:
        out += "| Changes in this version | %s |\n" % mdcell(info["changes"])
    if info["derived"]:
        out += "| Derived from | %s |\n" % mdcell(info["derived"])
    out += "\n## Datasets\n\n| Dataset | Label | Observations | Variables |\n|---|---|---|---|\n"
    for ds in stems:
        dd = dict(read_csv(meta_path(root, ds, "dataset"))[1:])
        out += "| %s | %s | %s | %s |\n" % (ds, mdcell(dd.get("label", "")), dd.get("n_obs", ""), dd.get("n_vars", ""))
    ds = stems[0]
    out += "\n## How to open the data\n\n"
    out += "Each dataset has the same files; the examples use `%s`.\n\n" % ds
    out += "**Stata.** Open the native file, or rebuild it from the csv:\n\n" + fe + "stata\n"
    if os.path.exists(os.path.join(root, "data", ds + ".dta")):
        out += 'use "data/%s.dta", clear\n' % ds
    out += 'do "setup/%s_setup.do"\n* or, with the datadeposit package installed:\ndatadeposit use ".", clear\n' % ds
    out += fe + "\n\n**R.** Read the native file, or rebuild it from the csv:\n\n" + fe + "r\n"
    if os.path.exists(os.path.join(root, "data", ds + ".rds")):
        out += '%s <- readRDS("data/%s.rds")\n' % (ds, ds)
    out += 'source("setup/%s_setup.R")   # creates %s\n' % (ds, ds) + fe + "\n\n"
    out += "**Python.** Rebuild it from the csv with pandas:\n\n" + fe + "python\nimport runpy\n"
    out += 'df = runpy.run_path("setup/%s_setup.py")["load"]()\n' % ds
    out += 'df.attrs["column_names_to_labels"]   # variable labels\n' + fe + "\n\n"
    out += ("**Excel.** Open `data/%s.csv` for the values and `codebook/%s_codebook.xlsx` for labels, "
            "value labels, and question text.\n\n" % (ds, ds))
    if info["profile"] == "lean":
        out += ("This deposit uses the lean profile: it keeps the native file and one csv, "
                "and the setup scripts build the R and Python versions on demand.\n\n")
    if info["profile"] == "nodata":
        out += ("This deposit holds no data files (nodata profile). The setup scripts expect "
                "the csv at `data/<dataset>.csv`.\n\n")
    out += "## Files\n\n| File | Bytes | What it is |\n|---|---|---|\n"
    for f in list_files(root):
        if f in ("README.md", "MANIFEST.json"):
            continue
        out += "| %s | %s | %s |\n" % (f, "{:,}".format(os.path.getsize(os.path.join(root, f))), what(f))
    out += "| MANIFEST.json | | sizes and sha256 hashes of every file |\n"
    out += "\n## Checking and changing this deposit\n\n"
    out += ('Run `datadeposit verify "<this folder>"` (Stata) or `deposit_verify()` (R or Python) to confirm '
            "that no file changed and that the csv still rebuilds the data exactly.\n\n")
    out += ("Do not edit files here. To publish changed data, load it with `datadeposit use`, make the changes, "
            "and write a new deposit with `version()` and `changes()`; the new deposit records this one as its parent.\n\n")
    out += "Folder layout and rules: deposit specification 1.0, https://github.com/ericabooth/datadeposit\n"
    spit(os.path.join(root, "README.md"), out)


def sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def write_manifest(root, stems, info, engines, do_hash=True):
    files = list_files(root)
    out = "{\n"
    out += '  "datadeposit": "1.0",\n'
    out += '  "package": %s,\n' % js("datadeposit " + info["package_version"])
    out += '  "software": %s,\n' % js(info["software"])
    out += '  "created": %s,\n' % js(now_iso())
    out += '  "title": %s,\n  "version": %s,\n  "changes": %s,\n  "profile": %s,\n' % (
        js(info["title"]), js(info["version"]), js(info["changes"]), js(info["profile"]))
    der = info["derived"]
    if not der:
        out += '  "derived_from": null,\n'
    else:
        parts = (der.split("|") + ["", "", ""])[:3]
        out += '  "derived_from": {"path": %s, "version": %s, "manifest_sha256": %s},\n' % tuple(js(p) for p in parts)
    out += '  "size_check": {"max_gb": %s, "largest_file_gb": %s, "override": %s},\n' % (
        fmtnum(info["max_gb"]), fmtnum(round(info["largest"] / 1e9, 3)), js(info["size_override"]))
    out += '  "datasets": [%s],\n' % ", ".join(js(s) for s in stems)
    out += '  "files": [\n'
    for i, f in enumerate(files):
        p = os.path.join(root, f)
        out += '    {"path": %s, "bytes": %d, "sha256": %s, "engine": %s}%s\n' % (
            js(f), os.path.getsize(p), js(sha256(p) if do_hash else ""), js(engines.get(f, info["engine"])),
            "," if i < len(files) - 1 else "")
    out += "  ]\n}\n"
    spit(os.path.join(root, "MANIFEST.json"), out)
    return sha256(os.path.join(root, "MANIFEST.json"))


def read_manifest(root):
    with open(os.path.join(root, "MANIFEST.json"), encoding="utf-8") as fh:
        return json.load(fh)
