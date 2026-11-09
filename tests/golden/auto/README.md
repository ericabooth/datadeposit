# Parity fixture auto

This folder is an archive-ready data deposit. It holds the data, a codebook, and setup scripts that rebuild the labelled data in Stata, R, and Python from the plain-text csv. It was written by datadeposit 0.1.0 in Stata 19.5 on 2026-11-09T16:50:24.

| Item | Value |
|---|---|
| Authors | Eric A. Booth |
| Version | 1 |
| Profile | full |
| License | CC-BY-4.0 |

## Datasets

| Dataset | Label | Observations | Variables |
|---|---|---|---|
| auto | 1978 automobile data | 74 | 12 |

## How to open the data

Each dataset has the same files; the examples use `auto`.

**Stata.** Open the native file, or rebuild it from the csv:

```stata
use "data/auto.dta", clear
do "setup/auto_setup.do"
* or, with the datadeposit package installed:
datadeposit use ".", clear
```

**R.** Read the native file, or rebuild it from the csv:

```r
auto <- readRDS("data/auto.rds")
source("setup/auto_setup.R")   # creates auto
```

**Python.** Rebuild it from the csv with pandas:

```python
import runpy
df = runpy.run_path("setup/auto_setup.py")["load"]()
df.attrs["column_names_to_labels"]   # variable labels
```

**Excel.** Open `data/auto.csv` for the values and `codebook/auto_codebook.xlsx` for labels, value labels, and question text.

## Files

| File | Bytes | What it is |
|---|---|---|
| codebook/auto_codebook.md | 2,949 | codebook to read |
| codebook/auto_codebook.xlsx | 7,226 | codebook as Excel sheets |
| codebook/auto_ddi.xml | 5,742 | DDI Codebook 2.5 for data archives |
| data/auto.csv | 4,472 | the data, plain text (codes, not labels) |
| data/auto.dta | 12,765 | the data for Stata |
| data/auto.rds | 3,311 | the data for R (base data.frame with attributes) |
| datapackage.json | 4,011 | Frictionless Data Package description |
| metadata/auto_chars.csv | 156 | notes and characteristics, including item text |
| metadata/auto_dataset.csv | 175 | dataset label, size, sort order |
| metadata/auto_frequencies.csv | 94 | counts for every labelled variable |
| metadata/auto_summary.csv | 920 | statistics for each variable |
| metadata/auto_valuelabels.csv | 69 | every value label |
| metadata/auto_variables.csv | 966 | one row per variable: type, format, label, value label set |
| setup/auto_setup.R | 13,458 | rebuilds the data in R |
| setup/auto_setup.do | 8,665 | rebuilds the data in Stata |
| setup/auto_setup.py | 9,432 | rebuilds the data in Python |
| MANIFEST.json | | sizes and sha256 hashes of every file |

## Checking and changing this deposit

Run `datadeposit verify "<this folder>"` (Stata), `deposit_verify()` (R or Python) to confirm that no file changed and that the csv still rebuilds the data exactly.

Do not edit files here. To publish changed data, load it with `datadeposit use`, make the changes, and write a new deposit with `version()` and `changes()`; the new deposit records this one as its parent.

Folder layout and rules: deposit specification 1.0, https://github.com/ericabooth/datadeposit
