# datadeposit workflows

This page walks through the tasks a mixed Stata, R, and Python team runs into most
often. Each task shows the Stata, R, and Python versions side by side, so you can hand
the page to a colleague who works in a different language. The examples use a dataset
named `survey`; replace it with your own.

## Make a deposit at the end of an analysis script

You write the deposit after the step that saves the analysis file, so every rerun of the
script refreshes the shared copy.

```stata
use "derived/survey_clean.dta", clear
datadeposit, to("share/survey_deposit") title("Resident survey, cleaned") ///
    authors("Eric A. Booth") onlarge(lean) replace
```
```r
library(datadeposit)
datadeposit(survey_clean, to = "share/survey_deposit", name = "survey",
            title = "Resident survey, cleaned", authors = "Eric A. Booth",
            on_large = "lean", replace = TRUE)
```
```python
from datadeposit import datadeposit
datadeposit(survey_clean, to="share/survey_deposit", name="survey",
            title="Resident survey, cleaned", authors="Eric A. Booth",
            on_large="lean", replace=True)
```

In R, a data frame read with `haven::read_dta()` or `haven::read_sav()` keeps its
variable and value labels, and a factor becomes labelled codes. In Python, pass the
metadata object from `pyreadstat` along with the data (`datadeposit(df, meta=meta, ...)`),
and a pandas Categorical becomes labelled codes. A `.dta` path passed straight to `datadeposit()`
keeps more: notes, characteristics, shared value label sets, and label languages, which
the R and Python packages read with their own `.dta` reader.

## Open a deposit someone sent you

You do not need the `datadeposit` package to use a deposit. Each language needs only
its own setup script, run from the deposit folder.

```stata
cd "survey_deposit"
do "setup/survey_setup.do"                 // or: use "data/survey.dta", clear
notes
char list q1[]                             // item text, source, universe, ...
```
```r
setwd("survey_deposit")
source("setup/survey_setup.R")             # creates the data frame `survey`
attr(survey$q1, "question")                # item text
attr(survey$q1, "labels")                  # value labels
```
```python
import runpy
df = runpy.run_path("survey_deposit/setup/survey_setup.py")["load"]()
df.attrs["datadeposit"]["questions"]["q1"]    # item text
df.attrs["variable_value_labels"]["q1"]       # value labels
```

In Excel, open `data/survey.csv` with Data > From Text/CSV (which reads the file as
UTF-8), and open `codebook/survey_codebook.xlsx` for labels, value labels, and question
text. The Markdown codebook `codebook/survey_codebook.md` displays as a formatted page on
GitHub and in most editors.

## Change the data and publish a new version

A deposit is a snapshot. You load it, change the data, and write a new deposit beside
the old one; the new deposit records the old one as its parent. When you leave out
`to()`, the new deposit goes to `survey_deposit_v2` beside the parent and gets
`version 2`.

```stata
datadeposit use "share/survey_deposit", clear
replace income = . if income < 0
datadeposit, changes("Negative incomes set to missing")
```
```r
d <- deposit_use("share/survey_deposit")
d$income[d$income < 0] <- NA
datadeposit(d, changes = "Negative incomes set to missing")
```
```python
from datadeposit import deposit_use, datadeposit
df = deposit_use("share/survey_deposit")
df.loc[df["income"] < 0, "income"] = None
datadeposit(df, changes="Negative incomes set to missing")
```

The new `MANIFEST.json` lists the parent under `derived_from`, with the parent's path,
version, and the sha256 hash of its manifest, so anyone can confirm which snapshot the
new one came from. Labels, notes, and characteristics carry over from the parent. A
variable you add gets types and labels inferred from the data, and you can label it
before you deposit (`label variable` in Stata, `attr(x, "label")` in R,
`df.attrs["column_names_to_labels"]` in Python).

We suggest you keep every published version and name them `_v2`, `_v3`, and so on, for
the same reason archives do: a result someone computed from version 1 has to stay
reproducible after version 2 exists. Only a draft that nobody else has used should be
overwritten with `replace`.

## Choose a profile for large data

The size check runs before anything is written. The table shows what each choice writes
for a 40 GB Stata file, using the size estimates `datadeposit` prints.

| Choice | Data files written | Roughly |
|---|---|---|
| default (`full`) | csv, dta, rds | stops: each copy is over the 5 GB limit |
| `lean` | csv, dta | two copies |
| `nodata` | none | a few megabytes of metadata and scripts |
| `allowlarge` | csv, dta, rds | three copies |

With `lean`, an R or Python user rebuilds the data from the csv with the setup script
when they need it, which takes time on a large file but costs no extra disk in the
deposit. For a script that runs unattended, `onlarge(lean)` (Stata) or
`on_large = "lean"` (R and Python) chooses `lean` by itself whenever the data cross the
limit. The round-trip check is skipped automatically above 1 GB. Run
`datadeposit verify` afterwards when you have time.

## Fix labels in Excel and apply them

```stata
datadeposit codebook, to(cb)                // metadata, codebook, setup; no data
* open cb/metadata/survey_variables.csv in Excel
* edit the label column; add new_name and drop columns if you need them
datadeposit apply using cb
```

`apply` reads the variables, value labels, and characteristics tables, matches rows to
variables by name, and reports any rows it could not match. It reads the codebook `.xlsx`
as well (`datadeposit apply using "cb/codebook/survey_codebook.xlsx"`). Excel limits a cell
to 32,767 characters, so the `.xlsx` marks longer text as cut, and `apply` leaves those
characteristics alone rather than shortening them.

## Check a deposit before you send it to an archive

```stata
datadeposit verify "share/survey_deposit_v2"
```

`verify` compares every file with `MANIFEST.json` (size and sha256) and rebuilds each
dataset from its csv. The R and Python versions are `deposit_verify()`. When the check
passes, you can zip the folder and upload it as it stands. Dataverse ingests the `.dta`
and csv as tabular files. The DDI file `codebook/survey_ddi.xml` and the README answer
most of the documentation questions in an ICPSR deposit form.
