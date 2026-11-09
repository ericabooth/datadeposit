# datadeposit folder specification, version 1.0

This file is the contract. The Stata, R, and Python implementations each
write deposits that follow it, and the parity tests in `tests/parity/` check
that they agree. When an implementation and this file disagree, this file
wins and the implementation has a bug.

## 1. Folder layout

A deposit is one folder holding one or more datasets. `<ds>` is a dataset's
file stem (for example `survey2025`).

```
<deposit>/
  README.md                     how to load the data in Stata, R, Python, and Excel
  MANIFEST.json                 every file: bytes, sha256, which engine wrote it
  datapackage.json              Frictionless Data Package (Table Schema) for all datasets
  data/
    <ds>.csv                    always written unless nodata; the portable copy
    <ds>.dta                    Stata 14+ format (release 118)
    <ds>.rds                    base R data.frame with attributes
    <ds>.xlsx                   optional; Excel copy (codes plus a labelled sheet)
    <ds>.sav                    optional; SPSS copy (needs haven or pyreadstat)
  metadata/
    <ds>_variables.csv          one row per variable
    <ds>_valuelabels.csv        one row per value label entry
    <ds>_chars.csv              one row per characteristic (Stata notes live here)
    <ds>_dataset.csv            dataset-level facts (key, value)
    <ds>_summary.csv            per-variable statistics (omitted with nostats)
    <ds>_frequencies.csv        counts for every labelled variable (omitted with nostats)
  codebook/
    <ds>_codebook.md            human-readable codebook
    <ds>_codebook.xlsx          the metadata tables as Excel sheets
    <ds>_ddi.xml                DDI Codebook 2.5
  setup/
    <ds>_setup.do               rebuilds the dataset from the CSV in Stata 16+
    <ds>_setup.R                rebuilds it in base R (haven optional)
    <ds>_setup.py               rebuilds it in Python with pandas
  docs/                         files passed through include()
```

The metadata tables are the single source of truth. The setup scripts read
them at run time, so the scripts are identical for every dataset except for
the dataset stem on one line. The JSON, XML, Markdown, and Excel files are
views of the same tables.

## 2. Profiles and the size check

| profile | data files written |
|---------|-------------------|
| `full` (default) | csv, dta, rds |
| `lean` | the native file plus csv; the setup scripts cover the other languages |
| `nodata` | none; metadata, codebook, and setup scripts only |

`formats()` overrides the profile with an explicit list drawn from
`csv dta rds xlsx sav`. The csv is required whenever any data file is written.

The native file is the format of the launching software: `.dta` in Stata,
`.rds` in R. Python has no labelled native format, so lean from Python
writes `.dta` when the source was a `.dta` file and csv only otherwise.

Before writing anything, the writer estimates the size of each data file.
If any single file would exceed `maxsize` (default 5 GB), the writer stops
with an error that names the file, its estimated size, and three ways
forward: `lean`, `nodata`, or `allowlarge`. `onlarge(lean)` makes the writer
switch to lean by itself instead of stopping. `lean` and `nodata` are never
blocked by the size check, because they add at most one portable copy.

## 3. CSV dialect (all tables and the data file)

- UTF-8, no byte-order mark, comma delimiter, `\n` line endings.
- First row holds the column names.
- Metadata tables quote every field. Data files quote every string field.
- A double quote inside a field is written as two double quotes.
- Fields may contain line breaks inside quotes. Readers must bind quotes
  (Stata `bindquotes(strict)`).

### Data values

| kind | written as |
|------|-----------|
| integer types (byte, int, long) | plain integer, for example `-23` |
| float | shortest text that reads back to the same float32 (Stata writes up to 9 significant digits) |
| double | shortest text that reads back to the same double (up to 17 significant digits) |
| string | the text, quoted |
| date (`%td`) | `YYYY-MM-DD` |
| datetime (`%tc`, `%tC`) | `YYYY-MM-DD HH:MM:SS.sss`, no time zone |
| system missing | empty field |
| extended missing `.a` to `.z` | the token `.a` to `.z` |

A leading zero may be dropped (`.3` and `0.3` are equal). Readers compare
numbers by value, not by text. Value labels never replace codes in the csv.
Other Stata `%t` formats (`%tm`, `%tq`, `%tw`, `%th`, `%ty`) stay integers
and keep their format in the metadata.

An empty string field means the empty string for string variables. R and
Python missing strings (`NA`, `None`) are written as empty fields, so the
NA versus empty distinction does not survive a deposit.

## 4. Metadata tables

All columns are text. Order rules use byte order (C locale), never locale
collation.

### `<ds>_variables.csv`

| column | meaning |
|--------|---------|
| `position` | 1-based column position in the data csv |
| `name` | the column name in the data csv (the original name) |
| `stata_name` | a valid Stata name (32 characters, letters, digits, `_`); equal to `name` for Stata data |
| `stata_type` | `byte int long float double str# strL` |
| `kind` | `numeric string date datetime` |
| `format` | Stata display format |
| `label` | the full variable label, any length |
| `value_labels` | name of the value label set, or empty |
| `extended_missing` | `1` if the csv column contains `.a`-`.z` tokens, else `0` |

Rows are in `position` order.

Stata limits variable labels to 80 characters. When a label is longer,
`setup.do` stores the first 80 characters as the label and the full text in
the characteristic `datadeposit_label`. A Stata writer that finds
`datadeposit_label` uses it as the label and does not repeat it in the
chars table, so the round trip is lossless. In the same way, when
`name` is not a valid Stata name, `setup.do` keeps it in the characteristic
`datadeposit_name`, and writers read it back as `name`.

### `<ds>_valuelabels.csv`

Columns `set`, `value`, `label`. `value` is an integer or an extended
missing token (`.a`). Every set that a variable uses is listed, in any
label language (the sets named by `_lang_l_*` characteristics count).
Stata's `save` drops sets that no variable uses, and deposits follow the
same rule so the csv metadata and the `.dta` always agree. Rows sort by
`set`, then numeric values ascending, then extended tokens `.a` to `.z`.

### `<ds>_chars.csv`

Columns `variable`, `char`, `text`. `variable` is a `stata_name` or `_dta`
for the dataset. Stata notes are the characteristics `note0` (the count)
and `note1`, `note2`, and so on; they are stored here unchanged, so `notes`
work again after `setup.do`. Label-language bookkeeping (`_lang_*`) is
also stored here unchanged. Rows sort with `_dta` first, then by variable
position, then by `char`.

Long survey item text usually lives in a characteristic. Stata stores at
most 67,783 bytes per characteristic. Longer text stays complete in this
table; `setup.do` truncates it and warns.

### `<ds>_dataset.csv`

Columns `key`, `value`. Keys, in this order: `dataset`, `label`, `n_obs`,
`n_vars`, `sortedby`, `question_char`, `source_file`, `spec_version`.
`question_char` names the characteristic that holds item text (for
example `question`); the R and Python setup scripts copy it to a
`question` attribute.

### `<ds>_summary.csv`

Columns `variable`, `kind`, `n_valid`, `n_missing`, `n_extended`, `min`,
`max`, `mean`, `sd`. For strings, `n_missing` counts empty strings and the
statistics are empty. For dates and datetimes, `min` and `max` are ISO text
and `mean`/`sd` are empty. Numbers use up to 10 significant digits; parity
tests compare them with a relative tolerance of 1e-6.

### `<ds>_frequencies.csv`

Columns `variable`, `value`, `label`, `count`. One block per variable with
a value label set: every labelled value (count may be 0), every observed
unlabelled value, and a final `.` row for system missing when present.
Blocks follow variable position; values follow the value label order.

## 5. Characteristics in R and Python

| Stata | R attribute | Python `df.attrs["datadeposit"]` key |
|-------|-------------|--------------------------------------|
| variable label | `label` | `column_labels[var]` |
| value labels | `labels` (haven_labelled when haven is installed) | `variable_value_labels[var]` |
| display format | `format.stata` | `formats[var]` |
| notes on a variable | `notes` (character vector) | `notes[var]` |
| other characteristics | `stata_chars` (named character vector) | `chars[var]` |
| item text (`question_char`) | `question` | `questions[var]` |
| extended missing | haven `tagged_na`, else `extended_missing` (row positions named by letter) | `extended_missing[var]` (letter to row indices) |
| dataset label, notes, chars | attributes on the data frame | `file_label`, `notes["_dta"]`, `chars["_dta"]` |

Python also mirrors pyreadstat names at the top of `df.attrs`
(`column_names_to_labels`, `variable_value_labels`, `value_labels`,
`variable_to_label`) so code written for pyreadstat keeps working.

## 6. Versions

A deposit is a snapshot. Writers never edit a deposit in place. A changed
dataset goes into a new deposit folder, by convention `<stem>_deposit_v2`.
`version()` and `changes()` record the version number and what changed.
When the data came from `datadeposit use`, the writer records the parent
deposit (path, version, and the sha256 of its MANIFEST.json) under
`derived_from`. `replace` overwrites a deposit only when the target is
itself a deposit (it holds a MANIFEST.json written by datadeposit); it
deletes the files that manifest lists and nothing else.

## 7. Parity contract

For the same input `.dta`, all three writers must produce:

- byte-identical `metadata/*_variables.csv`, `*_valuelabels.csv`,
  `*_chars.csv`, `*_dataset.csv`, `*_frequencies.csv`, and `setup/*`;
- data csv files equal by value (numbers at stored precision);
- `*_summary.csv` equal within tolerance;
- `datapackage.json` and `*_ddi.xml` equal after removing the fields that
  name the writer, its version, or the creation time.
