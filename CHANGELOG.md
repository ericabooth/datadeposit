# Changelog

## 0.1.1 (2026-11-12)

Fixes from review.

- Python setup script: with pandas older than 3, numeric columns that contain extended
  missing codes could come back off by the last binary digit. Text is now converted with
  Python's own `float()`, which is exact on every version. The same change applies when
  the Python package reads delimited source files.
- Stata setup script: files with more than 2,500 columns failed with `invalid numlist`,
  because Stata limits the column list in `import delimited`. Wide files are now read as
  text and converted with `real()`, which is exact. The script also says what to do when
  the file has more variables than `maxvar` allows.
- Default folder: a deposit with no `to()` now goes to the working directory in all three
  languages. Before, it went beside the source file, which put it inside data folders,
  recreated a source folder that had been deleted, and failed for data loaded from a web
  address. A new version of a loaded deposit still goes beside its parent.
- Hashes on Stata 16: `MANIFEST.json` was written without sha256 hashes on Stata 16, and
  on newer Stata when the calling do-file began with `version 16`, because the hash reader
  used a regular-expression feature those versions lack. Deposits and `verify` otherwise
  worked. Hashes are now written everywhere, and a test checks it.
- Round-trip check on wide files: the comparison needed room for twice the variables and
  failed past half of `maxvar`. It now compares one variable at a time.

## 0.1.0 (2026-11-09)

First release of the Stata, R, and Python packages and of deposit specification 1.0.

- `datadeposit` (create), `use`, `verify`, `codebook`, and `apply` in all three languages,
  writing the same folder: csv, dta, and rds copies (xlsx and sav optional), metadata
  tables, Markdown, Excel, and DDI 2.5 codebooks, a Frictionless datapackage.json, a
  README, and a MANIFEST.json with sha256 hashes.
- Setup scripts that rebuild the labelled data from the csv in base Stata 16, base R, and
  Python with pandas.
- Characteristics, notes, label languages, shared value label sets, labelled extended
  missing codes, and variable labels of any length carried between languages. Extended
  missing codes are stored inside the missing value in R and Python, so they stay with
  their rows.
- Exact round trips for doubles and floats, including a correction for base R's csv reader.
- Source files recognized by content: delimited text with any common delimiter or
  encoding, gzipped text, Stata, Excel, and SPSS files, whatever the extension. Folder
  mode deposits every table and lists what it skipped and why.
- A size check (5 GB by default) with the `lean`, `nodata`, `allowlarge`, and
  `onlarge(lean)` choices.
- Version lineage: a deposit made from `datadeposit use` data records its parent.
- Messages that give the fix when R, pandas, openpyxl, writexl, or a recent Stata is
  missing, and recovery from a deposit that was interrupted.
- Tests: a Stata battery (75 checks on Stata 16.1 and 19.5), pytest and testthat suites,
  a parity check of R and Python against Stata's reference deposits, and a torture suite
  of 29 awkward inputs run in all three languages.
