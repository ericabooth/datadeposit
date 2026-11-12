* datadeposit_battery.do -- Stata test battery for datadeposit
* Run from stata/tests on every Stata you support:
*     stata-mp -b do datadeposit_battery.do
* The last line of the log must read "BATTERY PASSED"; count the checks too.
version 16
clear all
set more off
local here = c(pwd)
adopath ++ "`here'/../src"
discard
local fx "`here'/../../tests/fixtures"
local out "`here'/../../tests/out/stata_battery_`=c(stata_version)'"
capture mkdir "`here'/../../tests/out"
shell rm -rf "`out'"
mkdir "`out'"
cd "`out'"
global DD_N 0
program define check
    args cond msg
    global DD_N = $DD_N + 1
    capture assert `cond'
    if _rc {
        di as err "FAIL $DD_N: `msg'"
        exit 9
    }
    di as txt "ok $DD_N: `msg'"
end

* --- 1. full deposit of the survey fixture -----------------------------------
use "`fx'/survey_edge.dta", clear
datadeposit, to(sv) title("Battery survey") authors("Eric A. Booth") license("CC-BY-4.0")
check `"r(verified) == "passed""' "survey deposit round trip passed"
check "strlen(r(manifest_sha256)) == 64" "sha256 hashes are written (also under version 16)"
local man = fileread("sv/MANIFEST.json")
check `"ustrregexm(`"`man'"', "codebook.md., .bytes.: [0-9]+, .sha256.: .[0-9a-f]{64}")"' "MANIFEST.json lists a hash for each file"
check `"r(profile) == "full""' "default profile is full"
foreach f in README.md MANIFEST.json datapackage.json data/survey_edge.csv data/survey_edge.dta ///
    data/survey_edge.rds metadata/survey_edge_variables.csv metadata/survey_edge_valuelabels.csv ///
    metadata/survey_edge_chars.csv metadata/survey_edge_dataset.csv metadata/survey_edge_summary.csv ///
    metadata/survey_edge_frequencies.csv codebook/survey_edge_codebook.md codebook/survey_edge_codebook.xlsx ///
    codebook/survey_edge_ddi.xml setup/survey_edge_setup.do setup/survey_edge_setup.R setup/survey_edge_setup.py {
    capture confirm file "sv/`f'"
    check "_rc == 0" "sv/`f' written"
}

* --- 2. item text, notes, label languages survive setup.do from the csv -------
use "`fx'/survey_edge.dta", clear
mata: st_local("q1_orig", st_global("q1[question]"))
mata: st_local("q2len_orig", strofreal(strlen(st_global("q2[question]"))))
local lab_orig : variable label q3
local dlab_orig : data label
quietly do sv/setup/survey_edge_setup.do sv
mata: st_local("same", strofreal(st_global("q1[question]") == st_local("q1_orig")))
check "`same' == 1" "q1 item text (quotes, dollar, backtick, line break) identical after csv rebuild"
mata: st_local("q2len", strofreal(strlen(st_global("q2[question]"))))
check "`q2len' == `q2len_orig'" "63,000-character item text kept in full"
check "`q2len' > 60000" "long item text is long"
local lab : variable label q3
mata: st_local("same", strofreal(st_local("lab") == st_local("lab_orig")))
check "`same' == 1" "variable label with backtick and quotes identical"
local dlab : data label
mata: st_local("same", strofreal(st_local("dlab") == st_local("dlab_orig")))
check "`same' == 1" "dataset label with dollar, backtick, quotes identical"
local n1 : char q1[note1]
check `"`"`n1'"' == "Recoded 6 to .r on 2025-01-15.""' "variable note kept"
local nn : char _dta[note0]
check "`nn' == 2" "dataset note count kept"
label language es
local les : variable label q1
check `"`"`les'"' == "Confianza en el gobierno local""' "Spanish label language kept"
local vl : value label q1
check `""`vl'" == "agree5_es""' "Spanish value label set attached in es"
label language en
check "q1 == .d | q1 != .d" "extended missing codes readable"
count if q1 == .d
local nd = r(N)
use "`fx'/survey_edge.dta", clear
count if q1 == .d
check "r(N) == `nd'" ".d count identical after rebuild"
check "income[1] == 0.1 + 0.2" "17-digit double exact"

* --- 3. verify, then tamper and verify again ----------------------------------
datadeposit verify sv
check "r(ok) == 1" "verify passes on a fresh deposit"
file open fh using "sv/metadata/survey_edge_dataset.csv", write append text
file write fh `""extra","row""' _n
file close fh
capture datadeposit verify sv
check "_rc == 9" "verify fails after a file is edited"

* --- 4. replace rules -----------------------------------------------------------
use "`fx'/survey_edge.dta", clear
capture datadeposit, to(sv)
check "_rc == 602" "existing deposit needs replace"
datadeposit, to(sv) replace nostats noverify
capture confirm file "sv/metadata/survey_edge_summary.csv"
check "_rc != 0" "replace removed files of the old deposit (nostats leaves no summary)"
mkdir notadeposit
file open fh using "notadeposit/keep.txt", write text replace
file write fh "keep me" _n
file close fh
capture datadeposit, to(notadeposit) replace
check "_rc == 602" "replace refuses a folder that is not a deposit"
capture confirm file "notadeposit/keep.txt"
check "_rc == 0" "nothing deleted from the non-deposit folder"

* --- 5. size check, lean, nodata, onlarge -------------------------------------------
sysuse auto, clear
capture datadeposit, to(big) maxsize(0.00001)
check "_rc == 498" "size check stops an oversized deposit"
mata: st_local("ex", strofreal(direxists("big")))
check "`ex' == 0" "nothing written when the size check stops"
datadeposit, to(big) maxsize(0.00001) onlarge(lean)
check `"r(profile) == "lean""' "onlarge(lean) switches to lean"
check `"r(formats) == "csv dta""' "lean writes the native file and the csv"
capture confirm file "big/data/auto.rds"
check "_rc != 0" "lean writes no rds"
capture confirm file "big/setup/auto_setup.R"
check "_rc == 0" "lean still writes the R setup script"
datadeposit, to(big2) maxsize(0.00001) allowlarge
check `"r(formats) == "csv dta rds""' "allowlarge writes every format"
datadeposit, to(lean1) lean
check `"r(profile) == "lean""' "lean on request"
datadeposit, to(nod) nodata
check `"r(profile) == "nodata""' "nodata profile"
capture confirm file "nod/data/auto.csv"
check "_rc != 0" "nodata writes no data"
capture confirm file "nod/metadata/auto_variables.csv"
check "_rc == 0" "nodata writes metadata"
datadeposit codebook, to(cb)
check `"r(profile) == "nodata""' "codebook subcommand is nodata"
datadeposit, to(fx1) formats(csv xlsx)
capture confirm file "fx1/data/auto.xlsx"
check "_rc == 0" "formats() writes an xlsx copy"
capture datadeposit, to(fx2) formats(dta)
check "_rc == 198" "formats() without csv is refused"

* --- 6. files mode and subsets -----------------------------------------------------
datadeposit, files("`fx'/auto.dta `fx'/nlsw88.dta") to(two) lean
check `"r(datasets) == "auto nlsw88""' "two datasets in one deposit"
check `"r(verified) == "passed""' "files mode round trip"
sysuse auto, clear
datadeposit make price foreign if foreign, to(sub) name(imports)
use sub/data/imports.dta, clear
check "c(N) == 22 & c(k) == 3" "varlist and if subset"
sysuse auto, clear
check "c(N) == 74 & c(k) == 12" "data in memory untouched by a subset deposit"

* --- 7. use, edit, and a new version that records its parent ------------------------
datadeposit use sv, clear
local src : char _dta[datadeposit_source]
check `"strpos(`"`src'"', "|survey_edge") > 0"' "use records the deposit as the source"
replace income = income * 2 if income < .
datadeposit, changes("Doubled income")
check `"strpos(r(path), "survey_edge_deposit_v2") > 0"' "next deposit defaults to <name>_deposit_v2 beside the parent"
local v2 `r(path)'
local man = fileread("`v2'/MANIFEST.json")
check `"strpos(`"`man'"', `""derived_from": {"path": ""') > 0"' "MANIFEST records the parent deposit"
check `"strpos(`"`man'"', `""version": "2""') > 0"' "new deposit is version 2"

* --- 8. apply edited metadata (iecodebook-style) --------------------------------------
sysuse auto, clear
datadeposit codebook, to(cb2)
import delimited using "cb2/metadata/auto_variables.csv", varnames(1) stringcols(_all) clear
replace label = "Miles per gallon (EPA)" if name == "mpg"
gen new_name = "turning_circle" if name == "turn"
gen drop = "1" if name == "trunk"
export delimited using "cb2/metadata/auto_variables.csv", replace quote
sysuse auto, clear
datadeposit apply using cb2
local l : variable label mpg
check `""`l'" == "Miles per gallon (EPA)""' "apply sets a label"
capture confirm variable turning_circle
check "_rc == 0" "apply renames"
capture confirm variable trunk
check "_rc != 0" "apply drops"
datadeposit apply using "cb2/codebook/auto_codebook.xlsx"
check "c(k) == 11" "apply reads the codebook xlsx"

* --- 9. pressure cases ---------------------------------------------------------------------
* data shipped with Stata: the default deposit goes to the working folder, not Stata's own
sysuse auto, clear
datadeposit
check `"strpos(r(path), c(sysdir_base)) == 0"' "default deposit of sysuse data stays out of Stata's folders"
capture confirm file "auto_deposit/MANIFEST.json"
check "_rc == 0" "default deposit of sysuse data is in the working folder"
* decimal comma setting must not reach the csv
set dp comma
gen double third = _n / 3
datadeposit, to(dpcomma) replace
set dp period
check `"r(verified) == "passed""' "set dp comma does not change the files"
* empty data, never saved
clear
gen long id = .
gen str5 s = ""
datadeposit, to(zero) replace
check `"r(verified) == "passed""' "zero observations"
* Unicode name, all-missing variable, labelled extended missing only, long text
clear
set obs 5
gen año = _n
gen allmiss = .
gen strL longtext = 3000 * "é"
gen byte b = .a
label define bl .a "Not asked"
label values b bl
datadeposit, to(uni) replace
check `"r(verified) == "passed""' "Unicode variable name, all-missing variable, 6,000-byte text"
* variable names that look like setup.do's own temporary names
clear
set obs 3
gen __dd_2 = 1
gen __dd_1 = 2
gen __000001 = 3
datadeposit, to(tmpnames) replace
check `"r(verified) == "passed""' "variables named like temporary names"
* a wide survey file stays fast (1,500 variables with item text)
clear
set obs 100
forvalues j = 1/1500 {
    gen byte q`j' = mod(_n + `j', 5) + 1
    char q`j'[question] "Full text of survey question number `j'."
}
label define five 1 "Never" 2 "Rarely" 3 "Sometimes" 4 "Often" 5 "Always"
label values q* five
timer clear 9
timer on 9
datadeposit, to(wide) replace
timer off 9
quietly timer list 9
check `"r(verified) == "passed""' "1,500-variable file round trip"
check "r(t9) < 120" "1,500-variable file finishes in under two minutes"
* targets that cannot be used
sysuse auto, clear
capture datadeposit, to("sv/README.md") replace
check "_rc == 602" "a file as the target is refused"
* text and Excel sources read by content
datadeposit, to(xl) formats(csv xlsx) replace
capture datadeposit, files("xl/data/auto.xlsx") to(fromxl) replace
check "_rc == 0" "an Excel file deposits"
capture datadeposit, files("sv/codebook/survey_edge_codebook.md") to(frommd) replace
check "_rc == 610" "a Markdown file is refused as data"

* --- 10. fixes from review (0.1.1) ------------------------------------------------------------
* the default deposit goes to the working directory, not into the source's folder
capture mkdir "02_cleaned"
sysuse auto, clear
save "02_cleaned/mini.dta", replace
use "02_cleaned/mini.dta", clear
datadeposit
capture confirm file "mini_deposit/MANIFEST.json"
check "_rc == 0" "default deposit is in the working directory"
mata: st_local("inside", strofreal(direxists("02_cleaned/mini_deposit")))
check "`inside' == 0" "default deposit is not inside the source data folder"
* the source folder has been deleted since the data were loaded
mkdir gone_dir
save "gone_dir/mini2.dta", replace
use "gone_dir/mini2.dta", clear
erase "gone_dir/mini2.dta"
rmdir gone_dir
datadeposit
mata: st_local("back", strofreal(direxists("gone_dir")))
check "`back' == 0" "a deleted source folder is not recreated"
capture confirm file "mini2_deposit/MANIFEST.json"
check "_rc == 0" "deposit of data from a deleted folder is in the working directory"
* a new version still goes beside its parent
datadeposit use mini_deposit, clear
datadeposit
check `"strpos(r(path), "mini_deposit_v2") > 0"' "version 2 goes beside its parent"
* more than 2,500 columns: setup.do must rebuild the file
clear
set obs 20
forvalues j = 1/2600 {
    gen byte q`j' = mod(_n + `j', 5)
}
gen str3 s = "abc"
gen double x = _n / 7
replace x = .b in 3
datadeposit, to(wide2600) replace nostats
check `"r(verified) == "passed""' "2,602-column file rebuilds from the csv with setup.do"

cd "`here'"
di as txt "{hline}"
di as txt "BATTERY PASSED: $DD_N checks on Stata `c(stata_version)'"
