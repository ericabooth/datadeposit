"""pytest battery for the Python datadeposit package (mirrors stata/tests/datadeposit_battery.do)."""

import json
import os
import pathlib

import numpy as np
import pandas as pd
import pytest

from datadeposit import DepositError, datadeposit, deposit_apply, deposit_use, deposit_verify
from datadeposit import dta, sources

FIX = pathlib.Path(__file__).resolve().parents[2] / "tests" / "fixtures"
SURVEY = str(FIX / "survey_edge.dta")


@pytest.fixture(scope="module")
def survey_deposit(tmp_path_factory):
    out = tmp_path_factory.mktemp("dep") / "sv"
    r = datadeposit(SURVEY, to=str(out), title="Battery survey", quiet=True)
    return out, r


def test_full_deposit_files(survey_deposit):
    out, r = survey_deposit
    assert r["verified"] == "passed"
    assert r["profile"] == "full"
    for f in ["README.md", "MANIFEST.json", "datapackage.json", "data/survey_edge.csv", "data/survey_edge.dta",
              "metadata/survey_edge_variables.csv", "metadata/survey_edge_chars.csv",
              "codebook/survey_edge_codebook.md", "codebook/survey_edge_ddi.xml", "setup/survey_edge_setup.py"]:
        assert (out / f).exists(), f


def test_rds_written_when_r_is_available(survey_deposit):
    from datadeposit import find_rscript
    out, _ = survey_deposit
    if find_rscript() is None:
        pytest.skip("R is not installed on this machine")
    assert (out / "data" / "survey_edge.rds").exists()


def test_no_r_is_reported_not_fatal(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("DATADEPOSIT_RSCRIPT", "none")
    r = datadeposit(SURVEY, to=str(tmp_path / "nor"))
    assert r["verified"] == "passed"
    assert not (tmp_path / "nor" / "data" / "survey_edge.rds").exists()
    assert "install R" in capsys.readouterr().out


def test_item_text_and_notes_survive(survey_deposit):
    out, _ = survey_deposit
    df = deposit_use(str(out))
    m = df.attrs["datadeposit"]
    src = dta.Reader(SURVEY)
    chars = {(v, c): t for v, c, t in src.chars}
    src.close()
    assert m["questions"]["q1"] == chars[("q1", "question")]
    assert len(m["questions"]["q2"]) > 60000
    assert m["notes"]["q1"] == ["Recoded 6 to .r on 2025-01-15.", "Second note on q1"]
    assert m["chars"]["q1"]["_lang_v_es"] == "Confianza en el gobierno local"
    assert m["variable_value_labels"]["q1"][".d"] == "Don't know"
    assert len(m["extended_missing"]["q1"]["d"]) == 26
    assert df["income"].iloc[0] == 0.1 + 0.2
    assert df["comment"].iloc[10] == "CRLF\r\ninside"
    assert df.attrs["file_label"] == 'Survey edge cases: $ `w1\' "Q"'


def test_dta_reader_matches_pyreadstat_values():
    pyreadstat = pytest.importorskip("pyreadstat")
    t = sources.from_dta(SURVEY)
    df, _ = pyreadstat.read_dta(SURVEY)
    for c in t.columns:
        if c.kind == "string":
            assert list(c.values) == list(df[c.name]), c.name
        elif c.kind == "numeric":
            assert np.array_equal(np.asarray(c.values, float), df[c.name].to_numpy(float), equal_nan=True), c.name


def test_dta_writer_round_trip(tmp_path):
    t = sources.from_dta(SURVEY)
    p = tmp_path / "x.dta"
    dta.write(str(p), t)
    u = sources.from_dta(str(p))
    for a, b in zip(t.columns, u.columns):
        assert (a.name, a.stata_type, a.format, a.label, a.value_labels, a.chars) == \
               (b.name, b.stata_type, b.format, b.label, b.value_labels, b.chars)
    assert t.value_label_sets == u.value_label_sets
    assert t.dta_chars == u.dta_chars


def test_verify_detects_tampering(tmp_path):
    out = tmp_path / "t"
    datadeposit(SURVEY, to=str(out), quiet=True, stats=False)
    assert deposit_verify(str(out), quiet=True)["ok"]
    with open(out / "metadata" / "survey_edge_dataset.csv", "a") as fh:
        fh.write('"extra","row"\n')
    assert not deposit_verify(str(out), quiet=True)["ok"]


def test_replace_rules(tmp_path):
    out = tmp_path / "r"
    datadeposit(SURVEY, to=str(out), quiet=True)
    with pytest.raises(DepositError):
        datadeposit(SURVEY, to=str(out), quiet=True)
    datadeposit(SURVEY, to=str(out), replace=True, stats=False, quiet=True)
    assert not (out / "metadata" / "survey_edge_summary.csv").exists()
    other = tmp_path / "keep"
    other.mkdir()
    (other / "keep.txt").write_text("keep me")
    with pytest.raises(DepositError):
        datadeposit(SURVEY, to=str(other), replace=True, quiet=True)
    assert (other / "keep.txt").exists()


def test_size_check_lean_nodata(tmp_path):
    with pytest.raises(DepositError, match="over the"):
        datadeposit(SURVEY, to=str(tmp_path / "b"), max_size_gb=1e-6, quiet=True)
    assert not (tmp_path / "b").exists()
    r = datadeposit(SURVEY, to=str(tmp_path / "b"), max_size_gb=1e-6, on_large="lean", quiet=True)
    assert r["profile"] == "lean" and r["formats"] == ["csv", "dta"]
    assert not (tmp_path / "b" / "data" / "survey_edge.rds").exists()
    r = datadeposit(SURVEY, to=str(tmp_path / "c"), max_size_gb=1e-6, allow_large=True, quiet=True)
    assert r["formats"] == ["csv", "dta", "rds"]
    r = datadeposit(SURVEY, to=str(tmp_path / "n"), nodata=True, quiet=True)
    assert not (tmp_path / "n" / "data" / "survey_edge.csv").exists()
    assert (tmp_path / "n" / "metadata" / "survey_edge_variables.csv").exists()
    with pytest.raises(DepositError):
        datadeposit(SURVEY, to=str(tmp_path / "f"), formats=["dta"], quiet=True)


def test_dataframe_source_and_new_version(tmp_path):
    df = pd.DataFrame({"id": [1, 2, 3], "score (pct)": [1.5, None, 3.25],
                       "grade": pd.Categorical(["A", "B", "A"]), "note": ["x", None, "z"]})
    df.attrs["column_names_to_labels"] = {"score (pct)": "S" * 120}
    r = datadeposit(df, to=str(tmp_path / "d"), name="frame", quiet=True)
    assert r["verified"] == "passed"
    back = deposit_use(str(tmp_path / "d"))
    assert list(back.columns) == ["id", "score (pct)", "grade", "note"]
    assert back.attrs["column_names_to_labels"]["score (pct)"] == "S" * 120
    back["id"] = back["id"] * 10
    r2 = datadeposit(back, changes="ids times ten", quiet=True)
    assert r2["path"].endswith("frame_deposit_v2")
    man = json.load(open(os.path.join(r2["path"], "MANIFEST.json")))
    assert man["version"] == "2"
    assert man["derived_from"]["path"] == os.path.abspath(str(tmp_path / "d"))


def test_apply(tmp_path):
    out = tmp_path / "cb"
    datadeposit(SURVEY, to=str(out), nodata=True, quiet=True)
    p = out / "metadata" / "survey_edge_variables.csv"
    v = pd.read_csv(p, dtype=str, keep_default_na=False)
    v.loc[v.name == "q1", "label"] = "Trust (local)"
    v["new_name"] = np.where(v.name == "zip", "zipcode", "")
    v["drop"] = np.where(v.name == "month", "1", "")
    v.to_csv(p, index=False)
    df = deposit_use(str(datadeposit(SURVEY, to=str(tmp_path / "base"), quiet=True)["path"]))
    new = deposit_apply(df, str(out))
    assert new.attrs["column_names_to_labels"]["q1"] == "Trust (local)"
    assert "zipcode" in new.columns and "month" not in new.columns
