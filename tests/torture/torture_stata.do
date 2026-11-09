* Deposit every torture input from Stata and record the outcome.
* Run from the repository root:  stata-mp -b do tests/torture/torture_stata.do
version 16
clear all
adopath ++ "stata/src"
local base "tests/out/torture"
local outdir `"`base'/stata/Eric's deposits/dépôt 2026"'
local files : dir "`base'/inputs" files "*"
local files : list sort files
tempname fh
file open `fh' using "`base'/results_stata.csv", write text replace
file write `fh' "file,outcome,detail" _n
foreach f of local files {
    local key = subinstr(subinstr("`f'", ".", "_", .), " ", "_", .)
    capture noisily datadeposit, files("`base'/inputs/`f'") to(`"`outdir'/`key'"') replace
    if _rc file write `fh' `""`f'",error,rc `=_rc'"' _n
    else file write `fh' `""`f'",ok,`r(verified)'"' _n
}
datadeposit, folder("`base'/inputs") pattern(*) to(`"`outdir'/whole_folder"') replace
file write `fh' `""(whole folder)",ok,`r(verified)' `r(datasets)'"' _n
* a deposit that crashed halfway: use refuses it, replace cleans it up
local crash `"`outdir'/crashed"'
capture mkdir `"`outdir'"'
capture mkdir `"`crash'"'
capture mkdir `"`crash'/data"'
tempname c1 c2
file open `c1' using `"`crash'/MANIFEST.json"', write text replace
file write `c1' `"{"datadeposit": "1.0", "status": "incomplete", "files": []}"' _n
file close `c1'
file open `c2' using `"`crash'/data/stray.csv"', write text replace
file write `c2' "x" _n "1" _n
file close `c2'
capture datadeposit use `"`crash'"', clear
local refused = cond(_rc, "yes", "no")
datadeposit, files("tests/fixtures/auto.dta") to(`"`crash'"') replace
local ver `r(verified)'
capture confirm file `"`crash'/data/stray.csv"'
local gone = cond(_rc, "yes", "no")
file write `fh' `""(crashed folder)",ok,`ver' use_refused=`refused' stray_removed=`gone'"' _n
file close `fh'
