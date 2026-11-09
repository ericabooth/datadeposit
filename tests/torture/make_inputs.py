#!/usr/bin/env python3
"""Write the torture-test inputs: the messy files a shared project folder really holds.

Every language's torture runner reads these same files, and torture_check.py
compares what each language did with EXPECT and with each other.
Run from the repository root:  python tests/torture/make_inputs.py
"""
import gzip
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "tests" / "out" / "torture" / "inputs"
FIX = ROOT / "tests" / "fixtures"

# file name -> (bytes, expected outcome); "ok" deposits, "error" must refuse with a reason
CASES = {
    "pipe.txt": (b'id|name|score\n1|Ana|3.5\n2|Bo "B" Lee|4\n3||\n', "ok"),
    "tabs.tsv": (b"id\tname\tscore\n1\tAna\t3.5\n2\tBo\t4\n", "ok"),
    "euro_semicolon.csv": (b"id;name;score\n1;Ana;3,5\n2;Bo;4,25\n", "ok"),
    "bom_crlf.csv": (b"\xef\xbb\xbfid,name\r\n1,Caf\xc3\xa9\r\n2,Bo\r\n", "ok"),
    "latin1.csv": (b"id,name\n1,Caf\xe9\n2,Bo\n", "ok"),
    "header_only.csv": (b"id,name\n", "ok"),
    "dup_names.csv": (b"id,id,x\n1,2,3\n", "ok"),
    "triple_names.csv": (b"id,id,id\n1,2,3\n", "ok"),
    "zip_codes.csv": (b"zip,amount,code\n01234,1.5,7\n78701,2,8\n00501,,9\n", "ok"),
    "na_tokens.csv": (b"id,x,country\n1,NA,NA\n2,3.5,US\n3,.,MX\n", "ok"),
    "multiline_quoted.csv": (b'id,comment\n1,"line one\nline two"\n2,"plain, with comma"\n', "ok"),
    "one_column.txt": (b"income\n100\n250\n\n300\n", "ok"),
    "bad_header_names.csv": (("id,Score (pct),2nd,año,in,a_name_that_is_far_too_long_for_stata_to_keep\n"
                              "1,2,3,4,5,6\n").encode("utf-8"), "ok"),
    "precise_numbers.csv": (b"x,y\n0.30000000000000004,1e-300\n123456789.12345679,-0.1\n", "ok"),
    "blank_lines.csv": (b"a,b\n1,2\n\n3,4\n\n", "ok"),
    "empty.csv": (b"", "error"),
    "blank_only.txt": (b"\n\n   \n", "error"),
    "ragged.csv": (b"a,b\n1,2,3\n4\n", "error"),
    "prose_notes.txt": (b"These are my notes about the survey.\nNothing tabular here.\n", "error"),
    "binary_named.txt": (bytes(range(256)) * 12, "error"),
    "utf16.txt": ("id,name\n1,Ana\n".encode("utf-16"), "ok"),
    "analysis.do": (b"sysuse auto\nreg price mpg\n", "error"),
    "model.R": (b"x <- 1\n", "error"),
    "readme.md": (b"# Notes\n", "error"),
    "fake.pdf": (b"%PDF-1.4\n%fake\n", "error"),
    "archive.zip": (b"PK\x03\x04" + b"\x00" * 30, "error"),
}
GZIPPED = {"pipe_gz.txt.gz": "pipe.txt"}
COPIES = {"disguised_dta.txt": "auto.dta", "my.data v2 (final).dta": "nlsw88.dta"}
EXPECT = {**{k: v[1] for k, v in CASES.items()}, **{k: "ok" for k in GZIPPED}, **{k: "ok" for k in COPIES}}


def main():
    if OUT.parent.exists():
        shutil.rmtree(OUT.parent)
    OUT.mkdir(parents=True)
    for name, (data, _) in CASES.items():
        (OUT / name).write_bytes(data)
    for name, src in GZIPPED.items():
        (OUT / name).write_bytes(gzip.compress(CASES[src][0], mtime=0))
    for name, src in COPIES.items():
        shutil.copy(FIX / src, OUT / name)
    with open(OUT.parent / "expected.csv", "w") as fh:
        fh.write("file,expect\n")
        for k in sorted(EXPECT):
            fh.write('"%s",%s\n' % (k, EXPECT[k]))
    print("wrote %d inputs to %s" % (len(EXPECT), OUT))


if __name__ == "__main__":
    main()
