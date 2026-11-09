* make_fixtures.do -- builds the test datasets for datadeposit
* Run from tests/fixtures:  do make_fixtures.do
* Hostile text is built with char() at run time, never typed literally, so
* the do-file itself is never macro-expanded into something else.
version 16
clear all
set seed 20261109


* ---------------------------------------------------------------------------
* survey_edge: the hard survey case
* ---------------------------------------------------------------------------
set obs 500
gen long id = 100000 + _n
gen byte wave = 1 + mod(_n, 3)
gen float weight = runiform() * 3
gen double income = round(rnormal(55000, 20000), 0.01)
replace income = 0.1 + 0.2 in 1
replace income = 9007199254740992 in 2
replace income = 1e-300 in 3
replace income = .r in 4
replace income = .d in 5
replace income = . in 6

foreach q in q1 q2 q3 {
    gen byte `q' = runiformint(1, 5)
    replace `q' = .d if runiform() < .05
    replace `q' = .r if runiform() < .03
    replace `q' = . if runiform() < .02
}
replace q3 = 9 in 7
label define agree5 1 "Strongly disagree" 2 "Disagree" 3 "Neither agree nor disagree" ///
    4 "Agree" 5 "Strongly agree" .d "Don't know" .r "Refused"
label values q1 q2 q3 agree5
label define spare 0 "unused set" 1 "kept anyway"

gen byte yesno = runiformint(0, 1)
label define yn 0 "No" 1 "Yes"
label values yesno yn

* open-ended text: commas, quotes, backticks, dollar signs, line breaks,
* tabs, leading/trailing spaces, Unicode, and empty strings
gen strL comment = ""
replace comment = "Plain comment, with a comma" in 1
replace comment = "He said " + char(34) + "fine" + char(34) + " and left" in 2
replace comment = "Line one" + char(10) + "Line two" + char(10) + "Line three" in 3
replace comment = "  padded both sides  " in 4
replace comment = "Caf" + uchar(233) + " " + uchar(241) + "and" + uchar(250) + " " + uchar(8220) + "curly" + uchar(8221) + " " + uchar(128512) in 5
replace comment = "macro " + char(96) + "x" + char(39) + " and global " + char(36) + "HOME and " + char(36) + "{y}" in 6
replace comment = "tab" + char(9) + "inside" in 7
replace comment = 3000 * "long " in 8
replace comment = "ends with a backslash " + char(92) in 9
replace comment = "quote-apostrophe " + char(34) + char(39) + " sequence" in 10
replace comment = "CRLF" + char(13) + char(10) + "inside" in 11

gen str5 zip = string(runiformint(0, 99999), "%05.0f")
replace zip = "01234" in 1

gen int intdate = mdy(1, 1, 2024) + runiformint(0, 600)
format intdate %td
replace intdate = .a in 8
gen double stamp = clock("2024-03-05 08:09:10.123", "YMDhms") + runiformint(0, 1e9)
format stamp %tc
gen int month = ym(2024, 1) + runiformint(0, 23)
format month %tm

gen byte a_variable_name_of_32_characters = 1
rename a_variable_name_of_32_characters abcdefghijklmnopqrstuvwxyz_12345

* variable labels with hostile characters; one exactly 80 characters
label variable id "Respondent ID"
label variable wave "Survey wave"
label variable weight "Analysis weight (raked)"
mata: st_varlabel("income", "Household income, " + char(36) + " per year")
label variable q1 "Trust in local government"
mata: st_varlabel("q2", "Trust in " + uchar(8220) + "state" + uchar(8221) + " government")
mata: st_varlabel("q3", "Trust in federal government " + char(96) + "fed" + char(39) + " " + char(34) + "DC" + char(34))
label variable yesno "Voted in 2024"
label variable comment "Open-ended comment"
label variable zip "ZIP code (kept as text)"
label variable intdate "Interview date"
label variable stamp "Submission timestamp (ms)"
label variable month "Field month"
label variable abcdefghijklmnopqrstuvwxyz_12345 "Exactly eighty characters in this label, counted carefully to land on 80 chars."

* full item text in characteristics (the usual survey practice)
mata: st_global("q1[question]", "How much do you trust your local government to do what is right?" + char(10) + ///
    "Interviewer: read options 1-5. Record " + char(34) + "don" + char(39) + "t know" + char(34) + ///
    " as .d. Cost " + char(36) + "5 incentive; tag " + char(96) + "Q1" + char(39) + ". " + 250 * "Extra wording. ")
mata: st_global("q2[question]", "How much do you trust your state government? " + 3000 * "Very long item text. ")
mata: st_global("q3[question]", "How much do you trust the federal government? (" + uchar(233) + "tude " + uchar(8212) + " short)")
char q1[source] "Pew-style trust battery, 2024"
char q1[universe] "All respondents"
notes q1: Recoded 6 to .r on 2025-01-15.
notes q1: Second note on q1
mata: st_global("_dta[note1]", "Dataset note with " + char(36) + "HOME, " + char(96) + "tick" + char(39) + " and " + char(34) + "quotes" + char(34))
mata: st_global("_dta[note2]", "Second dataset note" + char(10) + "with a line break")
mata: st_global("_dta[note0]", "2")
char _dta[project] "datadeposit fixture"

* a second label language (Spanish) for the trust battery
label language en, rename
label language es, new
label variable q1 "Confianza en el gobierno local"
label variable q3 "Confianza en el gobierno federal"
label variable id "ID del encuestado"
label variable q2 "Confianza en el gobierno estatal"
label define agree5_es 1 "Muy en desacuerdo" 2 "En desacuerdo" 3 "Ni de acuerdo ni en desacuerdo" ///
    4 "De acuerdo" 5 "Muy de acuerdo" .d "No sabe"
mata: st_vlmodify("agree5_es", .r, "Se neg" + uchar(243))
label values q1 q2 q3 agree5_es
label language en

mata: st_local("dlab", "Survey edge cases: " + char(36) + " " + char(96) + "w1" + char(39) + " " + char(34) + "Q" + char(34))
label data `"`macval(dlab)'"'
sort id
compress
save survey_edge, replace

* ---------------------------------------------------------------------------
* auto and nlsw88: ordinary shipped datasets
* ---------------------------------------------------------------------------
sysuse auto, clear
save auto, replace
sysuse nlsw88, clear
save nlsw88, replace

di as txt "fixtures written"
