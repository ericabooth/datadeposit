*! datadeposit setup file for Stata (deposit spec 1.0)
*! Rebuilds dataset survey_edge from data/survey_edge.csv and the tables in metadata/.
*!
*! From the deposit folder:     do setup/survey_edge_setup.do
*! From anywhere:               do "<deposit>/setup/survey_edge_setup.do" "<deposit>"
*! Also save a .dta:            do setup/survey_edge_setup.do . "survey_edge.dta"
*!
*! Needs Stata 16 or newer and no user-written commands. Replaces the data in
*! memory. Every label, value label, format, storage type, note, and
*! characteristic comes from the metadata tables, so you can edit those tables
*! (in Excel or any editor) and rerun this file.

if c(stata_version) < 16 {
    di as err "This setup file needs Stata 16 or newer; this is Stata `c(stata_version)'."
    di as err "  In Stata 14 or 15, open data/survey_edge.dta directly: it holds the same data and labels."
    di as err "  In Stata 13 or older, import data/survey_edge.csv with insheet or import delimited and take"
    di as err "  labels from metadata/survey_edge_variables.csv and metadata/survey_edge_valuelabels.csv."
    exit 9
}
version 16
args root saveas
local ds "survey_edge"
local vab = c(varabbrev)
set varabbrev off

* ---- find the deposit folder ------------------------------------------------
if `"`root'"' == "" | `"`root'"' == "." {
    local root
    foreach try in "." ".." {
        capture confirm file `"`try'/metadata/`ds'_variables.csv"'
        if _rc == 0 & `"`root'"' == "" local root `"`try'"'
    }
    if `"`root'"' == "" {
        di as err "setup: cannot find metadata/`ds'_variables.csv"
        di as err "  cd to the deposit folder, or pass its path as the first argument"
        set varabbrev `vab'
        exit 601
    }
}
foreach f in variables valuelabels chars dataset {
    capture confirm file `"`root'/metadata/`ds'_`f'.csv"'
    if _rc {
        di as err `"setup: missing `root'/metadata/`ds'_`f'.csv"'
        set varabbrev `vab'
        exit 601
    }
}
capture confirm file `"`root'/data/`ds'.csv"'
if _rc {
    di as err `"setup: missing `root'/data/`ds'.csv"'
    set varabbrev `vab'
    exit 601
}

local mopts varnames(1) case(preserve) encoding("utf-8") bindquotes(strict) ///
    maxquotedrows(unlimited) stringcols(_all) delimiters(",") clear

* ---- read the metadata tables into temporary frames -------------------------
tempname FV FL FC FD
foreach pair in "`FV' variables" "`FL' valuelabels" "`FC' chars" "`FD' dataset" {
    gettoken fr tab : pair
    local tab = strtrim(`"`tab'"')
    frame create `fr'
    frame `fr': quietly import delimited using `"`root'/metadata/`ds'_`tab'.csv"', `mopts'
}

frame `FV' {
    local K = _N
    local numcols
    local strcols
    forvalues i = 1/`K' {
        if kind[`i'] == "numeric" local numcols `numcols' `i'
        else local strcols `strcols' `i'
    }
}

* ---- read the data ----------------------------------------------------------
local dopts varnames(1) case(preserve) encoding("utf-8") bindquotes(strict) ///
    maxquotedrows(unlimited) delimiters(",") asdouble clear
* Stata accepts at most 2,500 column numbers in numericcols(), so a wider
* file is read as text and converted below with real(), which is exact
if `K' > c(maxvar) {
    di as err "setup: `ds' has `K' variables, more than this Stata session allows (`c(maxvar)')."
    di as err "  Type  set maxvar `=`K' + 100'  and run this file again (Stata BE stops at 2,048)."
    set varabbrev `vab'
    exit 900
}
if `K' <= 2000 {
    if "`numcols'" != "" local dopts `dopts' numericcols(`numcols')
    if "`strcols'" != "" local dopts `dopts' stringcols(`strcols')
}
else local dopts `dopts' stringcols(_all)
quietly import delimited using `"`root'/data/`ds'.csv"', `dopts'

if c(k) != `K' {
    di as err "setup: data/`ds'.csv has `c(k)' columns but the variables table lists `K'"
    set varabbrev `vab'
    exit 459
}

* ---- names: rename by position (two passes so names cannot collide) --------
local j 0
foreach v of varlist _all {
    local ++j
    tempvar hold
    rename `v' `hold'
    local hold_`j' `hold'
}
local order
forvalues j = 1/`K' {
    local nm = _frval(`FV', stata_name, `j')
    rename `hold_`j'' `nm'
    local order `order' `nm'
    * a name that is not a valid Stata name is kept in a characteristic
    local orig = _frval(`FV', name, `j')
    mata: st_local("renamed", strofreal(st_local("orig") != st_local("nm")))
    if `renamed' mata: st_global(st_local("nm") + "[datadeposit_name]", st_local("orig"))
}

* ---- types, dates, formats, labels ------------------------------------------
local nlab 0
forvalues j = 1/`K' {
    local v    = _frval(`FV', stata_name, `j')
    local typ  = _frval(`FV', stata_type, `j')
    local kind = _frval(`FV', kind, `j')
    local fmt  = _frval(`FV', format, `j')
    local vl   = _frval(`FV', value_labels, `j')
    if inlist("`kind'", "date", "datetime") {
        tempvar t
        if "`kind'" == "date" {
            quietly gen double `t' = cond(substr(`v', 1, 1) == ".", real(`v'), date(`v', "YMD"))
        }
        else if substr("`fmt'", 1, 3) == "%tC" {
            quietly gen double `t' = cond(substr(`v', 1, 1) == ".", real(`v'), Clock(`v', "YMDhms"))
        }
        else {
            quietly gen double `t' = cond(substr(`v', 1, 1) == ".", real(`v'), clock(`v', "YMDhms"))
        }
        quietly count if missing(`t') & `v' != "" & substr(`v', 1, 1) != "."
        if r(N) {
            di as err "setup: `v' has `r(N)' values that are not valid `kind's"
            set varabbrev `vab'
            exit 459
        }
        drop `v'
        rename `t' `v'
    }
    if "`kind'" == "numeric" {
        capture confirm string variable `v'
        if !_rc {
            tempvar t
            quietly gen double `t' = real(`v')
            quietly count if missing(`t') & `v' != "" & !regexm(`v', "^\.[a-z]?$")
            if r(N) {
                di as err "setup: `v' has `r(N)' values that are not numbers"
                set varabbrev `vab'
                exit 459
            }
            drop `v'
            rename `t' `v'
        }
    }
    if "`kind'" == "string" {
        * import delimited turns \r\n inside quoted text into \r; restore it
        quietly replace `v' = subinstr(`v', char(13), char(13) + char(10), .) if strpos(`v', char(13))
    }
    if "`typ'" == "float" quietly recast float `v', force
    else quietly recast `typ' `v'
    format `v' `fmt'
    * set every label, even an empty one: import delimited puts the original
    * column name in the label of any column it had to rename
    local lab = _frval(`FV', label, `j')
    mata: st_varlabel(st_local("v"), usubstr(st_local("lab"), 1, 80))
    mata: st_local("llen", strofreal(ustrlen(st_local("lab"))))
    if `llen' > 80 {
        mata: st_global(st_local("v") + "[datadeposit_label]", st_local("lab"))
    }
    if `llen' > 0 local ++nlab
    if "`vl'" != "" label values `v' `vl'
}
order `order'

* ---- value labels -----------------------------------------------------------
frame `FL': local NL = _N
forvalues i = 1/`NL' {
    local set = _frval(`FL', set, `i')
    local val = _frval(`FL', value, `i')
    local txt = _frval(`FL', label, `i')
    mata: st_vlmodify(st_local("set"), strtoreal(st_local("val")), st_local("txt"))
}

* ---- characteristics (includes notes and label languages) -------------------
frame `FC': local NC = _N
local nlong 0
forvalues i = 1/`NC' {
    local cv  = _frval(`FC', variable, `i')
    local cn  = _frval(`FC', char, `i')
    local txt = _frval(`FC', text, `i')
    mata: st_local("clen", strofreal(strlen(st_local("txt"))))
    if `clen' > 67783 {
        * Stata keeps at most 67,783 bytes; cut on a character boundary
        local ++nlong
        mata: __dd_s = usubstr(st_local("txt"), 1, 67783); while (strlen(__dd_s) > 67783) __dd_s = usubstr(__dd_s, 1, ustrlen(__dd_s) - 1); st_global(st_local("cv") + "[" + st_local("cn") + "]", __dd_s)
        mata: mata drop __dd_s
    }
    else {
        mata: st_global(st_local("cv") + "[" + st_local("cn") + "]", st_local("txt"))
    }
}
if `nlong' {
    di as txt "setup: note: `nlong' characteristic(s) exceed Stata's 67,783-byte limit and were cut;"
    di as txt "       the full text is in metadata/`ds'_chars.csv"
}

* ---- dataset label and sort order -------------------------------------------
frame `FD' {
    local dlab
    local sortby
    forvalues i = 1/`=_N' {
        if key[`i'] == "label"    local dlab = value[`i']
        if key[`i'] == "sortedby" local sortby = value[`i']
    }
}
* label data keeps dollar signs, backticks and quotes when the macro is passed through
* macval inside compound quotes; only the two-character sequence "' breaks it,
* so on failure that sequence gets a space and the change is reported
mata: st_local("dlen", strofreal(strlen(st_local("dlab"))))
if `dlen' > 0 {
    capture label data `"`macval(dlab)'"'
    if _rc {
        mata: st_local("dlab", subinstr(st_local("dlab"), char(34) + char(39), char(34) + " " + char(39)))
        capture label data `"`macval(dlab)'"'
        if _rc di as txt "setup: note: the dataset label could not be set; it is in metadata/`ds'_dataset.csv"
        else di as txt "setup: note: a space was added inside the dataset label so Stata could store it"
    }
}
if "`sortby'" != "" sort `sortby', stable

foreach fr in `FV' `FL' `FC' `FD' {
    capture frame drop `fr'
}
set varabbrev `vab'

di as txt "setup: built " as res "`ds'" as txt " (" as res c(N) as txt " obs, " ///
    as res c(k) as txt " vars, " as res `nlab' as txt " variable labels, " ///
    as res `NL' as txt " value labels, " as res `NC' as txt " characteristics)"

if `"`saveas'"' != "" {
    save `"`saveas'"', replace
}
