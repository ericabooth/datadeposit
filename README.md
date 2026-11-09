# datadeposit

**One command in Stata, R, or Python turns a dataset into an archive-ready folder that opens the same way in all three, and in Excel.**

A team that works across Stata, R, and Python loses information every time a file
changes hands. A `.dta` read into R through haven keeps its value labels but drops the
notes and the characteristics in which survey files usually store item text. A csv sent to a
Python colleague arrives with no labels at all. `datadeposit` fixes this by writing the
kind of folder that ICPSR and Harvard Dataverse distribute: the data as plain-text csv
plus native copies, a codebook, and setup scripts that rebuild the fully labelled data
from the csv in Stata, R, and Python.

The command is the same in each language, and the three implementations write the same
folder. The metadata tables, setup scripts, codebook, and DDI file match byte for byte,
and the data files match value for value. A parity test suite checks this on every change.

```stata
datadeposit, to(survey_deposit) title("Spring 2026 resident survey") replace
```
```r
datadeposit("survey.dta", to = "survey_deposit", title = "Spring 2026 resident survey", replace = TRUE)
```
```python
datadeposit("survey.dta", to="survey_deposit", title="Spring 2026 resident survey", replace=True)
```

## Install

All three packages are in this repository, and each installs straight from GitHub.

```stata
net install datadeposit, from("https://raw.githubusercontent.com/ericabooth/datadeposit/main/") replace
```
```r
remotes::install_github("ericabooth/datadeposit", subdir = "r")
```
```bash
pip install "git+https://github.com/ericabooth/datadeposit.git#subdirectory=python"
```

The Stata command needs Stata 16 or newer and no other user-written commands. The R
package needs R 4.1 or newer and jsonlite; haven, writexl, and readxl are optional. The
Python package needs pandas; openpyxl (for the Excel codebook) and pyreadstat (for an SPSS
copy) are optional. This line installs both with the package:

```bash
pip install "datadeposit[all] @ git+https://github.com/ericabooth/datadeposit.git#subdirectory=python"
```

## What a deposit holds

```
survey_deposit/
  README.md               how to open the data in Stata, R, Python, and Excel
  MANIFEST.json           size, sha256, and writing engine of every file
  datapackage.json        Frictionless Data Package description
  data/                   survey.csv, survey.dta, survey.rds
  metadata/               the tables that drive everything (variables, value labels,
                          notes and characteristics, dataset facts, statistics, frequencies)
  codebook/               survey_codebook.md, survey_codebook.xlsx, survey_ddi.xml (DDI 2.5)
  setup/                  survey_setup.do, survey_setup.R, survey_setup.py
  docs/                   anything you pass with include(), such as the questionnaire
```

The metadata tables are plain csv files that Excel opens, and the setup scripts read them
when they run. A colleague who spots a typo in a label can fix it in the table and rerun
the script. Each setup script needs only its own language: base Stata 16, base R, or Python
with pandas. Someone who receives the folder does not need `datadeposit` to use it.

## Why this layout

- **Nobody is locked out.** The csv opens in anything, and the three setup scripts give
  Stata, R, and Python users the labelled version without a conversion step.
- **Survey documentation survives.** Item text in characteristics, notes, labelled
  extended missing codes (`.d` "Don't know", `.r` "Refused"), shared value label sets, and
  label languages all reach R and Python. Stata's `svyset` and `xtset` settings come back
  in Stata.
- **Numbers do not drift.** Doubles round-trip through the csv to the last binary digit,
  floats stay floats, and dates and datetimes are written as ISO text. Base R's csv parser is
  not exact for 17-digit numbers, so the R setup script corrects its result.
- **You can check it.** `MANIFEST.json` lists a sha256 hash for every file, and
  `datadeposit verify` rebuilds each dataset from its csv and compares it with the
  deposit.
- **It is ready for an archive.** The DDI Codebook 2.5 file, the Frictionless description,
  and the README follow the conventions that ICPSR, Dataverse, and data journals ask for.

## A deposit at the end of every script

We suggest you add a deposit line after the step that saves your analysis file. Each rerun
then refreshes a portable copy that the whole team can use.

```stata
* ... cleaning and merging ...
save "derived/survey_clean.dta", replace
datadeposit, to("share/survey_deposit") title("Resident survey, cleaned") ///
    authors("Eric A. Booth; Jane Analyst") license("CC-BY-4.0") onlarge(lean) replace
```

`replace` removes the earlier deposit's files first, so a rerun never leaves a stale copy
beside a new one. It refuses to touch a folder that is not a deposit. `onlarge(lean)`
keeps the line safe as the data grow (see the next section). The R and Python versions
take the same options, spelled `replace = TRUE` and `on_large = "lean"`.

## Large files

Before writing anything, `datadeposit` estimates the size of each data file. When one
would exceed 5 GB, it stops and writes nothing, because a full deposit of a 40 GB `.dta`
would add a 40 GB csv and a 40 GB `.rds` beside it. The message lists the choices:

| Option | What you get |
|---|---|
| `lean` | the native file (`.dta` from Stata, `.rds` from R) plus one csv and all three setup scripts; users of the other languages build their copy from the csv |
| `nodata` | metadata, codebook, and setup scripts only, for when you share the data another way |
| `allowlarge` | every format anyway |
| `maxsize(#)` | a different limit, in GB |
| `onlarge(lean)` | switch to `lean` automatically instead of stopping |

The lean profile is the middle ground for large files: one native copy, one portable copy,
and scripts that let anyone rebuild the labelled data in their own language when they need
it. `MANIFEST.json` records which choice applied. `nostats` skips the summary statistics
and frequency tables, which saves time on files of several gigabytes.

## Picking up a deposit and publishing changes

A deposit is a snapshot, and you should not edit its files. Editing breaks the hashes in
`MANIFEST.json`, and anyone who already used the deposit could no longer reproduce their
results. To publish changed data, write a new deposit beside the old one. This is how ICPSR
and Dataverse version datasets: each version is complete on its own and names its parent.

```stata
datadeposit use "share/survey_deposit", clear      // the .dta, or the csv through setup.do
replace income = . if income < 0
datadeposit, changes("Negative incomes set to missing")
```

After `datadeposit use`, a deposit with no `to()` goes to `survey_deposit_v2` next to the
original and sets `version(2)`. Its `MANIFEST.json` records the parent's path, version, and
manifest hash under `derived_from`, and its README states the change. The same works across
languages, so an R user can load a deposit that Stata wrote, change it, and publish version 3:

```r
d <- deposit_use("share/survey_deposit_v2")
d$income[d$income > 1e6] <- NA
datadeposit(d, changes = "Top-coded incomes over $1 million")
```
```python
df = deposit_use("share/survey_deposit_v3")
df.loc[df["age"] < 18, "age"] = None
datadeposit(df, changes="Removed ages under 18")
```

While a deposit is still a draft that nobody else has used, overwriting it with `replace`
is fine. [docs/workflows.md](docs/workflows.md) walks through each step in each language.

## Editing labels in Excel

`datadeposit codebook` writes the metadata, codebook, and setup scripts without data
copies. You can edit the variables table in Excel (labels, formats, value label sets)
and add a `new_name` column to rename variables or a `drop` column to drop them. Then
apply the edits to the data, in the manner of `iecodebook apply`:

```stata
datadeposit codebook, to(cb)
* edit cb/metadata/survey_variables.csv or cb/codebook/survey_codebook.xlsx
datadeposit apply using cb
```

R has `deposit_apply(df, "cb")` and Python has `deposit_apply(df, "cb")`.

## How the three versions stay in sync

- **One specification.** [spec/DEPOSIT-SPEC.md](spec/DEPOSIT-SPEC.md) defines every file,
  column, and formatting rule. When an implementation disagrees with it, the implementation
  has a bug.
- **One copy of each setup script.** `spec/templates/` holds the three setup scripts.
  `tools/sync_templates.py` copies them into the R and Python packages and embeds them in
  the Stata ado-file, and `--check` fails when any copy drifts. The same tool writes the
  version number from `VERSION` into every package.
- **Golden deposits.** Stata writes reference deposits of the test fixtures into
  `tests/golden/`. On every push, GitHub Actions rebuilds them in R and Python on Linux,
  macOS, and Windows and compares them file by file. Stata cannot run on GitHub's machines,
  so `tools/run_all_tests.sh` runs the Stata battery locally on Stata 16 and on the current
  Stata.
- **Survey edge cases.** `tests/fixtures/make_fixtures.do` builds a survey file with every
  case we know to be hard: item text of 63,000 characters, quotes, dollar signs, backticks,
  line breaks (including Windows `\r\n`) in labels and data, English and Spanish label
  languages, shared and labelled extended missing codes, 17-digit doubles, and a 32-character
  variable name.

## Compared with tools you may already use

| Need | descsave | datadictionary | iecodebook | DDIwR | datadeposit |
|---|---|---|---|---|---|
| Relabel a csv in Stata | do-file | do-file | from Excel | setup file | setup.do |
| Relabel a csv in R and Python | | | | R only | setup.R and setup.py |
| Characteristics and notes kept outside Stata | | | | | yes |
| Label languages | | | | | yes |
| Excel codebook | | yes | yes | | yes |
| Apply edits from Excel (rename, relabel, drop) | | | yes | | yes |
| Recode values from Excel | | | yes | | no |
| Harmonize and append waves | | detects changes | `iecodebook append` | | no |
| DDI Codebook XML | | | | read and write | write |
| SPSS and SAS setup files | | | | yes | no (an SPSS `.sav` copy is optional) |
| Hashes, version lineage, size check | | | | | yes |

For packaging data to share or archive across Stata, R, Python, and Excel, `datadeposit`
covers what the other tools do and adds the R and Python halves. It does not yet recode
values from a codebook, harmonize waves before appending, read DDI files, or write SPSS
and SAS syntax. Keep `iecodebook append`, `datadictionary`'s wave comparison, or DDIwR for
those tasks.

## Speed

On an Apple M-series Mac, a full deposit of a 200,000-row, 12-variable file (14 MB as a
`.dta`), including the round-trip check, takes about 10 seconds in Stata and Python and
about 20 seconds in R. The time grows roughly in line with the number of values, so plan
on minutes for files of a few gigabytes, and use `lean`, `nostats`, or `noverify` to cut
it.

## Known limits

- Stata keeps at most 67,783 bytes in one characteristic. Longer text stays complete in
  the metadata table and in R and Python, and `setup.do` warns when it has to cut.
- A lone carriage return inside a text value (an old Mac line ending) comes back from
  `setup.do` as a Windows line break, because Stata's csv import cannot keep it. A
  Windows `\r\n` comes back exactly. Base R keeps carriage returns only in csv files
  under 1 GB.
- An R or Python missing string (`NA`, `None`) and an empty string are both written as
  an empty field, so the difference does not survive a deposit.
- Excel opens the csv directly, but on Windows a double-click can misread accented
  characters. Use Data > From Text/CSV, or add `xlsx` to `formats()`.
- Windows support for the Stata command's R step (`rds`, `sav`) and hashing is written
  but not yet tested on a Windows machine.

## Repository layout

```
spec/           the folder contract and the master setup-script templates
stata/          datadeposit.ado, datadeposit.sthlp, and the Stata battery
r/              the R package (R CMD check clean)
python/         the Python package
tests/          fixtures, golden deposits, parity checker
tools/          template sync, all-language test runner, SSC zip builder
docs/           longer walkthroughs
```

## Author

Eric A. Booth (eric.a.booth@gmail.com). MIT license.
