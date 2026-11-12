{smcl}
{* *! version 0.1.1  12nov2026}{...}
{vieweralsosee "datadictionary (if installed)" "help datadictionary"}{...}
{vieweralsosee "[D] notes" "help notes"}{...}
{vieweralsosee "[D] label language" "help label_language"}{...}
{viewerjumpto "Syntax" "datadeposit##syntax"}{...}
{viewerjumpto "Description" "datadeposit##description"}{...}
{viewerjumpto "Options" "datadeposit##options"}{...}
{viewerjumpto "The deposit folder" "datadeposit##folder"}{...}
{viewerjumpto "Files it can read" "datadeposit##files"}{...}
{viewerjumpto "Survey data" "datadeposit##survey"}{...}
{viewerjumpto "Large files" "datadeposit##large"}{...}
{viewerjumpto "New versions" "datadeposit##versions"}{...}
{viewerjumpto "Missing software" "datadeposit##missing"}{...}
{viewerjumpto "Examples" "datadeposit##examples"}{...}
{viewerjumpto "Stored results" "datadeposit##results"}{...}
{viewerjumpto "Author" "datadeposit##author"}{...}
{title:Title}

{phang}
{bf:datadeposit} {hline 2} Prepare data, documentation, and code for colleagues the way you would for a data archive, from Stata, R, or Python
{p_end}


{marker syntax}{...}
{title:Syntax}

{pstd}Write a deposit of the data in memory{p_end}

{p 8 16 2}
{cmd:datadeposit} [{varlist}] {ifin} [{cmd:,} {it:options}]
{p_end}

{pstd}Write a deposit of one or more data files, or of every data file in a folder{p_end}

{p 8 16 2}
{cmd:datadeposit} {cmd:,} {opt files(filelist)} | {opt folder(path)} [{opt pattern(pattern)} {it:options}]
{p_end}

{pstd}Load, check, document, or relabel{p_end}

{p 8 16 2}
{cmd:datadeposit use} {it:folder} [{cmd:,} {opt clear} {opt name(dataset)} {opt csv}]
{p_end}
{p 8 16 2}
{cmd:datadeposit verify} {it:folder} [{cmd:,} {opt nohash}]
{p_end}
{p 8 16 2}
{cmd:datadeposit codebook} [{varlist}] {ifin} [{cmd:,} {it:options}]
{p_end}
{p 8 16 2}
{cmd:datadeposit apply using} {it:folder}|{it:codebook.xlsx} [{cmd:,} {opt name(dataset)} {opt types} {opt nochars}]
{p_end}

{synoptset 24 tabbed}{...}
{synopthdr}
{synoptline}
{syntab:Where and what}
{synopt:{opt to(folder)}}deposit folder; default is {it:name}{cmd:_deposit} in the working directory{p_end}
{synopt:{opt files(filelist)}}deposit these files in place of the data in memory{p_end}
{synopt:{opt folder(path)}}deposit every data file in this folder{p_end}
{synopt:{opt pattern(pattern)}}which files in {cmd:folder()} to consider; default {cmd:*.dta}{p_end}
{synopt:{opt name(string)}}dataset name inside the deposit; default is the file name{p_end}
{synopt:{opt formats(list)}}data files to write, from {cmd:csv dta rds xlsx sav}; default {cmd:csv dta rds}{p_end}
{synopt:{opt lean}}write the {cmd:.dta} and the {cmd:.csv} only; the setup scripts cover R and Python{p_end}
{synopt:{opt nodata}}write metadata, codebook, and setup scripts, but no data files{p_end}
{synopt:{opt replace}}overwrite an earlier deposit in {cmd:to()}{p_end}
{synopt:{opt include(filelist)}}copy questionnaires, do-files, or other documents into {cmd:docs/}{p_end}

{syntab:Size check}
{synopt:{opt maxsize(#)}}largest data file allowed, in GB; default {cmd:5}{p_end}
{synopt:{opt allowlarge}}write every format even when a file exceeds {cmd:maxsize()}{p_end}
{synopt:{opt onlarge(lean|stop)}}switch to {cmd:lean} instead of stopping when a file would exceed {cmd:maxsize()}{p_end}

{syntab:Documentation}
{synopt:{opt title(string)}}deposit title for the README and the metadata{p_end}
{synopt:{opt authors(string)}}authors, separated by semicolons{p_end}
{synopt:{opt description(string)}}a paragraph describing the data{p_end}
{synopt:{opt license(string)}}license, for example {cmd:CC-BY-4.0}{p_end}
{synopt:{opt version(string)}}deposit version; default {cmd:1}, or the parent's version plus one{p_end}
{synopt:{opt changes(string)}}what changed in this version{p_end}
{synopt:{opt question(charname)}}characteristic that holds item text; found automatically when named {cmd:question}, {cmd:item}, {cmd:qtext}, and similar{p_end}

{syntab:Speed and checks}
{synopt:{opt nostats}}skip summary statistics and frequencies{p_end}
{synopt:{opt noverify}}skip the round-trip check{p_end}
{synopt:{opt nohash}}skip sha256 hashes in {cmd:MANIFEST.json}{p_end}
{synopt:{opt rscript(path)}}Rscript to use for the {cmd:.rds} copy; default searches the usual places and {cmd:$DATADEPOSIT_RSCRIPT}{p_end}
{synoptline}


{marker description}{...}
{title:Description}

{pstd}
{cmd:datadeposit} is for teams that work in more than one statistical language.
One analyst cleans a survey in Stata, a colleague models it in R, a partner reads
it in Python, and a program officer opens it in Excel. Each handoff usually loses
something: value labels, notes, the wording of the survey questions, or the
precision of a number.
{p_end}

{pstd}
Data archives such as ICPSR and Harvard Dataverse distribute each study as a
folder with the data in plain text, a codebook, and setup files that rebuild the
labelled data in each statistical package. {cmd:datadeposit} writes that kind of
folder, which we call a deposit, so that your colleagues and partners receive
your analysis file in the form an archive would give them. A colleague who works
in R or Python gets the same variable labels, value labels, notes, and survey
question text that you see in Stata, and the folder is already in the shape an
archive expects.
{p_end}

{pstd}
The same command exists in R ({cmd:datadeposit()}) and Python
({cmd:datadeposit.datadeposit()}). All three write the same folder: the metadata
tables, setup scripts, codebook, and DDI file are identical byte for byte, and the
data files agree value for value. The repository's tests compare the three.
{p_end}

{pstd}
We suggest you make {cmd:datadeposit} the last line of an analysis do-file. Once
the cleaned file is saved, the command writes a portable copy that anyone on the
team can open, and each rerun of the do-file refreshes it.
{p_end}


{marker options}{...}
{title:Options}

{phang}
{opt to(folder)} names the deposit folder. Without it, the folder is
{it:name}{cmd:_deposit} in the working directory ({cmd:pwd} shows it), and the
receipt prints its full path. The deposit is not written beside the source file,
because that folder is often a raw or cleaned data folder that other do-files
read. The one exception is a new version of a deposit you loaded with
{cmd:datadeposit use}: it goes beside its parent as {it:name}{cmd:_deposit_v}{it:#}.
We suggest you give {cmd:to()} in a project do-file, so the location does not
depend on the working directory.
{p_end}

{phang}
{opt files(filelist)} and {opt folder(path)} deposit files from disk and leave the
data in memory untouched. The files can be Stata, delimited text, Excel, or SPSS
files; see {help datadeposit##files:Files it can read}. With {cmd:folder()},
{cmd:pattern("*")} considers every file: {cmd:datadeposit} deposits each data file
it finds and lists each file it skipped with the reason.
{p_end}

{phang}
{opt formats(list)} lists the data files to write. {cmd:csv} is required because
every setup script reads it. {cmd:dta} is written by Stata itself. {cmd:rds} and
{cmd:sav} are written by running the deposit's own {cmd:setup.R} with Rscript, so
they need R (and haven for {cmd:sav}); without R, {cmd:datadeposit} skips them and
says so. {cmd:xlsx} writes a sheet of codes and a sheet of value labels.
{p_end}

{phang}
{opt lean} keeps the {cmd:.dta} and one {cmd:.csv}, and leaves out the {cmd:.rds}.
R and Python users rebuild the data from the {cmd:.csv} with the setup scripts.
Use it for large files; see {help datadeposit##large:Large files}.
{p_end}

{phang}
{opt nodata} writes everything except data files. {cmd:datadeposit codebook} is a
synonym.
{p_end}

{phang}
{opt replace} overwrites an earlier deposit. It refuses a folder that does not
hold a {cmd:MANIFEST.json} written by {cmd:datadeposit}, and it deletes only the
files that manifest lists, so it never empties an unrelated folder.
{p_end}

{phang}
{opt maxsize(#)}, {opt allowlarge}, and {opt onlarge()} control the size check
described under {help datadeposit##large:Large files}.
{p_end}

{phang}
{opt question(charname)} names the characteristic that holds item text. The text
appears in the codebook, in the DDI file as the question wording, and as a
{cmd:question} attribute in R and Python.
{p_end}

{phang}
{opt noverify} skips the round-trip check. By default {cmd:datadeposit} rebuilds
each dataset from its {cmd:.csv} with the deposit's {cmd:setup.do} and confirms
that values, types, formats, labels, value labels, notes, and characteristics all
match. The check is skipped automatically for data over 1 GB; run
{cmd:datadeposit verify} on those when convenient.
{p_end}

{phang}
{cmd:datadeposit use} loads a deposit: the {cmd:.dta} when there is one, otherwise
the {cmd:.csv} through {cmd:setup.do} ({opt csv} forces the second route). It
records the deposit as the parent of any later deposit made from these data.
{p_end}

{phang}
{cmd:datadeposit verify} checks every file against {cmd:MANIFEST.json} (size and
sha256) and repeats the round-trip check. It exits with return code 9 when
anything differs.
{p_end}

{phang}
{cmd:datadeposit apply} reads metadata tables that you have edited, in a
deposit's {cmd:metadata/} folder or in its codebook {cmd:.xlsx}, and applies the
labels, value labels, formats, and characteristics to the data in memory. Add a
column {cmd:new_name} to rename variables and a column {cmd:drop} (1 to drop) to
the variables table, in the manner of {cmd:iecodebook apply}. {opt types} also
applies storage types; {opt nochars} leaves characteristics alone.
{p_end}


{marker folder}{...}
{title:The deposit folder}

{p2colset 5 42 44 2}{...}
{p2col:{cmd:README.md}}how to open the data in each language, and the file list{p_end}
{p2col:{cmd:MANIFEST.json}}size, sha256, and writing engine of every file{p_end}
{p2col:{cmd:datapackage.json}}Frictionless Data Package description{p_end}
{p2col:{cmd:data/}{it:ds}{cmd:.csv .dta .rds}}the data{p_end}
{p2col:{cmd:metadata/}{it:ds}{cmd:_variables.csv}}one row per variable{p_end}
{p2col:{cmd:metadata/}{it:ds}{cmd:_valuelabels.csv}}every value label{p_end}
{p2col:{cmd:metadata/}{it:ds}{cmd:_chars.csv}}notes and characteristics{p_end}
{p2col:{cmd:metadata/}{it:ds}{cmd:_summary.csv}, {cmd:_frequencies.csv}}statistics{p_end}
{p2col:{cmd:codebook/}{it:ds}{cmd:_codebook.md .xlsx}}codebook to read{p_end}
{p2col:{cmd:codebook/}{it:ds}{cmd:_ddi.xml}}DDI Codebook 2.5{p_end}
{p2col:{cmd:setup/}{it:ds}{cmd:_setup.do .R .py}}rebuild the data from the csv{p_end}
{p2colreset}{...}

{pstd}
The metadata tables are plain {cmd:.csv} files that Excel opens. The setup scripts
read them at run time, so you can correct a label in the table and rerun the
script. The full rules are in {cmd:spec/DEPOSIT-SPEC.md} in the GitHub repository.
{p_end}


{marker files}{...}
{title:Files it can read}

{pstd}
With {cmd:files()} or {cmd:folder()}, {cmd:datadeposit} decides what a file is by
reading its first bytes, so the file's extension does not have to be right. It
prints a note for each thing it changed on the way in.
{p_end}

{phang2}o Delimited text with commas, tabs, pipes, or semicolons, whatever the
extension ({cmd:.csv}, {cmd:.txt}, {cmd:.tsv}, {cmd:.dat}), including semicolon files
with decimal commas and gzipped files.{p_end}
{phang2}o Text in Latin-1, UTF-8 with a byte-order mark, or UTF-16, which is
converted to UTF-8.{p_end}
{phang2}o Stata, Excel, and SPSS files, including ones with the wrong extension.{p_end}
{phang2}o Columns of ZIP codes or IDs that start with 0 stay text. {cmd:NA},
{cmd:N/A}, {cmd:NaN}, {cmd:null}, and {cmd:.} in a numeric column are read as
missing.{p_end}
{phang2}o Repeated or invalid column names are renamed; the original name stays in
the csv and the codebook, and in {cmd:[datadeposit_name]}.{p_end}

{pstd}
{cmd:datadeposit} refuses a file that is not a table and says why: binary data
named {cmd:.txt}, prose notes, an empty file, or a table whose rows have different
numbers of fields (the message names the first bad row). Code and documents
({cmd:.do}, {cmd:.R}, {cmd:.py}, {cmd:.pdf}, {cmd:.md}) are skipped in a folder; pass
them with {cmd:include()} to copy them into {cmd:docs/}. A {cmd:strL} variable that
holds binary data cannot pass through a csv, so the command stops and names it.
{p_end}


{marker survey}{...}
{title:Survey data}

{pstd}
Survey files keep much of their documentation outside variable labels, and
{cmd:datadeposit} carries all of it into R and Python:
{p_end}

{phang2}o Item text in characteristics (for example {cmd:q1[question]}), including
quotes, dollar signs, backticks, line breaks, and Unicode, up to Stata's limit of
67,783 bytes per characteristic.{p_end}
{phang2}o Notes ({cmd:notes}), on variables and on the dataset.{p_end}
{phang2}o Variable labels of any length from R or Python; Stata keeps the first 80
characters as the label and the full text in {cmd:[datadeposit_label]}.{p_end}
{phang2}o Shared value label sets, labelled extended missing codes such as
{cmd:.d} "Don't know" and {cmd:.r} "Refused", and label languages
({cmd:label language}). In R and Python the missing code is stored inside the
missing value, so it stays with its row through filters, sorts, and merges.{p_end}
{phang2}o {cmd:svyset}, {cmd:xtset}, and other settings that Stata stores as
characteristics.{p_end}

{pstd}
Doubles round-trip exactly through the {cmd:.csv} (17 significant digits), floats
round-trip to the same float, dates and datetimes are written as ISO text, and ZIP
codes and other numeric-looking text stay text.
{p_end}


{marker large}{...}
{title:Large files}

{pstd}
Before writing anything, {cmd:datadeposit} estimates the size of every data file.
When one would exceed {cmd:maxsize()} (5 GB unless you say otherwise), it stops,
writes nothing, and lists three ways forward:
{p_end}

{phang2}{cmd:lean}: the {cmd:.dta} plus one {cmd:.csv} and the setup scripts. The
{cmd:.rds} is left out, and R and Python users build their copy from the {cmd:.csv}.{p_end}
{phang2}{cmd:nodata}: metadata, codebook, and setup scripts only.{p_end}
{phang2}{cmd:allowlarge}: every format anyway.{p_end}

{pstd}
For a deposit at the end of a do-file whose data grow over time, add
{cmd:onlarge(lean)}: the command then switches to {cmd:lean} on its own when the
data pass the limit, and records that in {cmd:MANIFEST.json}. {cmd:replace}
removes the earlier deposit's files first, so a rerun does not leave stale copies
beside new ones.
{p_end}


{marker versions}{...}
{title:New versions}

{pstd}
Treat a deposit as a snapshot and do not edit its files: an edit breaks the hashes
in {cmd:MANIFEST.json}, and anyone who already used the deposit could no longer
reproduce their results. To publish changed data, write a new deposit beside the
old one. {cmd:datadeposit use} loads the old deposit and remembers it; after your
edits, {cmd:datadeposit} with no {cmd:to()} writes {it:name}{cmd:_deposit_v2} next
to it, sets {cmd:version(2)}, and records the parent's path, version, and manifest
hash under {cmd:derived_from}. This follows the way ICPSR and Dataverse version
datasets: every version is complete on its own. While a deposit is still a draft
that nobody has used, {cmd:replace} is fine.
{p_end}


{marker missing}{...}
{title:Missing software}

{pstd}
{cmd:datadeposit} finishes the deposit with what the machine has and tells you how
to add the rest.
{p_end}

{phang2}o {bf:No R on this machine.} The {cmd:.rds} copy is skipped and a note says
so. R users can still rebuild the data with {cmd:setup/}{it:name}{cmd:_setup.R}. To
write the {cmd:.rds}, install R from {browse "https://cloud.r-project.org"}, or point
to it with {cmd:rscript()} or the environment variable {cmd:DATADEPOSIT_RSCRIPT}.
{cmd:lean} stops asking for an {cmd:.rds}.{p_end}
{phang2}o {bf:A colleague has Stata 14 or 15.} {cmd:setup.do} needs Stata 16 and
says so; the colleague opens {cmd:data/}{it:name}{cmd:.dta} directly, which holds
the same data and labels.{p_end}
{phang2}o {bf:A colleague has Stata 13 or older.} The same message gives the
steps: import {cmd:data/}{it:name}{cmd:.csv} and take labels from the
{cmd:metadata} tables.{p_end}
{phang2}o {bf:A colleague has no statistical software.} The csv and
{cmd:codebook/}{it:name}{cmd:_codebook.xlsx} open in Excel.{p_end}
{phang2}o {bf:A deposit was interrupted.} {cmd:datadeposit use} and
{cmd:datadeposit verify} report that it did not finish; run {cmd:datadeposit}
again with {cmd:replace}.{p_end}


{marker examples}{...}
{title:Examples}

{pstd}Deposit the data in memory at the end of a do-file{p_end}
{phang2}{cmd:. sysuse nlsw88, clear}{p_end}
{phang2}{cmd:. datadeposit, to(nlsw88_deposit) title("NLSW 1988 extract") authors("Eric A. Booth") replace}{p_end}

{pstd}Large data: never stop, step down to lean when needed{p_end}
{phang2}{cmd:. datadeposit, to(claims_deposit) onlarge(lean) replace}{p_end}

{pstd}Every data file in a folder, whatever its type{p_end}
{phang2}{cmd:. datadeposit, folder("raw") pattern("*") to(raw_deposit)}{p_end}

{pstd}A pipe-delimited text file{p_end}
{phang2}{cmd:. datadeposit, files("responses.txt") to(responses_deposit)}{p_end}

{pstd}Several files in one deposit, with the questionnaire{p_end}
{phang2}{cmd:. datadeposit, files("wave1.dta wave2.dta wave3.dta") to(panel_deposit) include("questionnaire.pdf")}{p_end}

{pstd}A subset, renamed{p_end}
{phang2}{cmd:. datadeposit id q1-q20 if wave == 3, to(w3_deposit) name(wave3)}{p_end}

{pstd}Pick up a deposit, change it, and publish version 2{p_end}
{phang2}{cmd:. datadeposit use nlsw88_deposit, clear}{p_end}
{phang2}{cmd:. replace wage = . if wage > 40}{p_end}
{phang2}{cmd:. datadeposit, changes("Set implausible wages to missing")}{p_end}

{pstd}Check a deposit someone sent you{p_end}
{phang2}{cmd:. datadeposit verify nlsw88_deposit}{p_end}

{pstd}Relabel from an edited codebook{p_end}
{phang2}{cmd:. datadeposit codebook, to(cb)}{p_end}
{phang2}{it:(edit cb/metadata/nlsw88_variables.csv in Excel: labels, new_name, drop)}{p_end}
{phang2}{cmd:. datadeposit apply using cb}{p_end}


{marker results}{...}
{title:Stored results}

{pstd}{cmd:datadeposit} stores the following in {cmd:r()}:{p_end}

{synoptset 22 tabbed}{...}
{p2col 5 22 26 2: Scalars}{p_end}
{synopt:{cmd:r(largest_gb)}}estimated size of the largest data file, in GB{p_end}
{p2col 5 22 26 2: Macros}{p_end}
{synopt:{cmd:r(path)}}deposit folder{p_end}
{synopt:{cmd:r(datasets)}}dataset names{p_end}
{synopt:{cmd:r(formats)}}data formats written{p_end}
{synopt:{cmd:r(profile)}}{cmd:full}, {cmd:lean}, {cmd:nodata}, or {cmd:custom}{p_end}
{synopt:{cmd:r(verified)}}result of the round-trip check{p_end}
{synopt:{cmd:r(manifest_sha256)}}sha256 of {cmd:MANIFEST.json}{p_end}

{pstd}{cmd:datadeposit verify} stores {cmd:r(ok)}, {cmd:r(files_bad)}, and
{cmd:r(roundtrip_ok)}. {cmd:datadeposit use} stores {cmd:r(dataset)},
{cmd:r(source)}, {cmd:r(deposit)}, and {cmd:r(version)}.{p_end}


{marker author}{...}
{title:Author}

{pstd}Eric A. Booth{break}
{browse "https://github.com/ericabooth/datadeposit"}{p_end}

{pstd}
Requires Stata 16 or newer. No other community-contributed commands are needed. The
{cmd:.rds} and {cmd:.sav} copies need R; hashes use {cmd:shasum} or
{cmd:sha256sum} (macOS and Linux) or {cmd:certutil} (Windows).
{p_end}
