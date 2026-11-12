# Parity fixture survey_edge

This folder is an archive-ready data deposit. It holds the data, a codebook, and setup scripts that rebuild the labelled data in Stata, R, and Python from the plain-text csv. It was written by datadeposit 0.1.1 in Stata 19.5 on 2026-11-12T07:02:38.

| Item | Value |
|---|---|
| Authors | Eric A. Booth |
| Version | 1 |
| Profile | full |
| License | CC-BY-4.0 |

## Datasets

| Dataset | Label | Observations | Variables |
|---|---|---|---|
| survey_edge | Survey edge cases: $ `w1' "Q" | 500 | 14 |

## How to open the data

Each dataset has the same files; the examples use `survey_edge`.

**Stata.** Open the native file, or rebuild it from the csv:

```stata
use "data/survey_edge.dta", clear
do "setup/survey_edge_setup.do"
* or, with the datadeposit package installed:
datadeposit use ".", clear
```

**R.** Read the native file, or rebuild it from the csv:

```r
survey_edge <- readRDS("data/survey_edge.rds")
source("setup/survey_edge_setup.R")   # creates survey_edge
```

**Python.** Rebuild it from the csv with pandas:

```python
import runpy
df = runpy.run_path("setup/survey_edge_setup.py")["load"]()
df.attrs["column_names_to_labels"]   # variable labels
```

**Excel.** Open `data/survey_edge.csv` for the values and `codebook/survey_edge_codebook.xlsx` for labels, value labels, and question text.

## Files

| File | Bytes | What it is |
|---|---|---|
| codebook/survey_edge_codebook.md | 72,194 | codebook to read |
| codebook/survey_edge_codebook.xlsx | 9,362 | codebook as Excel sheets |
| codebook/survey_edge_ddi.xml | 76,866 | DDI Codebook 2.5 for data archives |
| data/survey_edge.csv | 64,319 | the data, plain text (codes, not labels) |
| data/survey_edge.dta | 122,373 | the data for Stata |
| data/survey_edge.rds | 20,347 | the data for R (base data.frame with attributes) |
| datapackage.json | 72,818 | Frictionless Data Package description |
| metadata/survey_edge_chars.csv | 67,783 | notes and characteristics, including item text |
| metadata/survey_edge_dataset.csv | 204 | dataset label, size, sort order |
| metadata/survey_edge_frequencies.csv | 772 | counts for every labelled variable |
| metadata/survey_edge_summary.csv | 1,043 | statistics for each variable |
| metadata/survey_edge_valuelabels.csv | 486 | every value label |
| metadata/survey_edge_variables.csv | 1,281 | one row per variable: type, format, label, value label set |
| setup/survey_edge_setup.R | 13,514 | rebuilds the data in R |
| setup/survey_edge_setup.do | 9,698 | rebuilds the data in Stata |
| setup/survey_edge_setup.py | 9,786 | rebuilds the data in Python |
| MANIFEST.json | | sizes and sha256 hashes of every file |

## Checking and changing this deposit

Run `datadeposit verify "<this folder>"` (Stata), `deposit_verify()` (R or Python) to confirm that no file changed and that the csv still rebuilds the data exactly.

Do not edit files here. To publish changed data, load it with `datadeposit use`, make the changes, and write a new deposit with `version()` and `changes()`; the new deposit records this one as its parent.

Folder layout and rules: deposit specification 1.0, https://github.com/ericabooth/datadeposit
