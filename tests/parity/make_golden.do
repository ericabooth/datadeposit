* make_golden.do -- Stata writes the reference deposits that R and Python must match
* Run from the repository root:  stata-mp -b do tests/parity/make_golden.do
version 16
clear all
adopath ++ "stata/src"
foreach ds in survey_edge auto nlsw88 {
    use "tests/fixtures/`ds'.dta", clear
    datadeposit, to("tests/golden/`ds'") replace title("Parity fixture `ds'") ///
        authors("Eric A. Booth") license("CC-BY-4.0")
}
