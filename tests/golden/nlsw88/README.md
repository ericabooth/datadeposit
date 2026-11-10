# Parity fixture nlsw88

This folder is an archive-ready data deposit. It holds the data, a codebook, and setup scripts that rebuild the labelled data in Stata, R, and Python from the plain-text csv. It was written by datadeposit 0.1.0 in Stata 19.5 on 2026-11-09T21:22:44.

| Item | Value |
|---|---|
| Authors | Eric A. Booth |
| Version | 1 |
| Profile | full |
| License | CC-BY-4.0 |

## Datasets

| Dataset | Label | Observations | Variables |
|---|---|---|---|
| nlsw88 | NLSW, 1988 extract | 2246 | 17 |

## How to open the data

Each dataset has the same files; the examples use `nlsw88`.

**Stata.** Open the native file, or rebuild it from the csv:

```stata
use "data/nlsw88.dta", clear
do "setup/nlsw88_setup.do"
* or, with the datadeposit package installed:
datadeposit use ".", clear
```

**R.** Read the native file, or rebuild it from the csv:

```r
nlsw88 <- readRDS("data/nlsw88.rds")
source("setup/nlsw88_setup.R")   # creates nlsw88
```

**Python.** Rebuild it from the csv with pandas:

```python
import runpy
df = runpy.run_path("setup/nlsw88_setup.py")["load"]()
df.attrs["column_names_to_labels"]   # variable labels
```

**Excel.** Open `data/nlsw88.csv` for the values and `codebook/nlsw88_codebook.xlsx` for labels, value labels, and question text.

## Files

| File | Bytes | What it is |
|---|---|---|
| codebook/nlsw88_codebook.md | 6,171 | codebook to read |
| codebook/nlsw88_codebook.xlsx | 9,833 | codebook as Excel sheets |
| codebook/nlsw88_ddi.xml | 13,999 | DDI Codebook 2.5 for data archives |
| data/nlsw88.csv | 143,689 | the data, plain text (codes, not labels) |
| data/nlsw88.dta | 76,434 | the data for Stata |
| data/nlsw88.rds | 42,957 | the data for R (base data.frame with attributes) |
| datapackage.json | 7,365 | Frictionless Data Package description |
| metadata/nlsw88_chars.csv | 405 | notes and characteristics, including item text |
| metadata/nlsw88_dataset.csv | 178 | dataset label, size, sort order |
| metadata/nlsw88_frequencies.csv | 1,620 | counts for every labelled variable |
| metadata/nlsw88_summary.csv | 1,346 | statistics for each variable |
| metadata/nlsw88_valuelabels.csv | 1,236 | every value label |
| metadata/nlsw88_variables.csv | 1,412 | one row per variable: type, format, label, value label set |
| setup/nlsw88_setup.R | 13,474 | rebuilds the data in R |
| setup/nlsw88_setup.do | 8,687 | rebuilds the data in Stata |
| setup/nlsw88_setup.py | 9,444 | rebuilds the data in Python |
| MANIFEST.json | | sizes and sha256 hashes of every file |

## Checking and changing this deposit

Run `datadeposit verify "<this folder>"` (Stata), `deposit_verify()` (R or Python) to confirm that no file changed and that the csv still rebuilds the data exactly.

Do not edit files here. To publish changed data, load it with `datadeposit use`, make the changes, and write a new deposit with `version()` and `changes()`; the new deposit records this one as its parent.

Folder layout and rules: deposit specification 1.0, https://github.com/ericabooth/datadeposit
