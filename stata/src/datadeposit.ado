*! version 0.1.0  09nov2026  Eric A. Booth
*! datadeposit: archive-ready data deposits that open the same way in Stata, R, Python, and Excel
*
*  One command, the same in all three languages. It writes a folder with the
*  data (csv plus native copies), the codebook (Markdown, Excel, DDI 2.5 XML,
*  Frictionless datapackage.json), the metadata tables that drive everything,
*  and setup scripts that rebuild the labelled data from the csv in Stata, R,
*  and Python. The folder contract lives in spec/DEPOSIT-SPEC.md of the
*  GitHub repository (ericabooth/datadeposit).
*
*  Subcommands:   datadeposit [create] ...     write a deposit (default)
*                 datadeposit use ...          load a deposit
*                 datadeposit verify ...       check hashes and round trips
*                 datadeposit codebook ...     metadata, codebook, setup only
*                 datadeposit apply ...        apply edited metadata tables
*
*  Mata note: every Mata function below is private to this ado-file. Mata code
*  here never contains a backtick or a dollar sign, because Stata expands
*  macros when it compiles an ado-file.

program define datadeposit, rclass
    if c(stata_version) < 16 {
        di as err "datadeposit needs Stata 16 or newer; this is Stata `c(stata_version)'."
        di as err "  To open a deposit someone sent you in Stata 14 or 15, use its data/*.dta file directly."
        di as err "  Stata 13 and older cannot read that file; ask for the deposit's csv and setup.do to be run"
        di as err "  on a newer Stata, or import data/*.csv and apply labels from metadata/*_variables.csv."
        exit 9
    }
    version 16
    gettoken sub rest : 0, parse(" ,")
    local sub = strtrim(`"`sub'"')
    if `"`sub'"' == "create" {
        _ddp_create `rest'
    }
    else if `"`sub'"' == "use" {
        _ddp_use `rest'
    }
    else if `"`sub'"' == "verify" {
        _ddp_verify `rest'
    }
    else if `"`sub'"' == "codebook" {
        _ddp_create `rest' nodata_alias
    }
    else if `"`sub'"' == "apply" {
        _ddp_apply `rest'
    }
    else {
        _ddp_create `0'
    }
    return add
end

* ===========================================================================
* create
* ===========================================================================
program define _ddp_create, rclass
    version 16
    * codebook subcommand arrives with a trailing token; turn it into nodata
    local codebook_alias 0
    if strpos(`"`0'"', "nodata_alias") {
        local 0 = subinstr(`"`0'"', "nodata_alias", "", 1)
        local codebook_alias 1
    }
    syntax [varlist(default=none)] [if] [in] [, to(string) name(string) ///
        files(string asis) folder(string) pattern(string)              ///
        formats(string) lean nodata replace maxsize(real 5)            ///
        allowlarge onlarge(string) title(string) authors(string)       ///
        description(string) license(string) version(string)           ///
        changes(string) include(string asis) question(string)          ///
        nostats noverify rscript(string) nohash ]
    if `codebook_alias' & "`nodata'" == "" local nodata nodata
    if "`nodata'" != "" local data nodata

    * ---- options --------------------------------------------------------
    if "`lean'" != "" & "`data'" == "nodata" {
        di as err "lean and nodata cannot be combined"
        exit 198
    }
    if `maxsize' <= 0 {
        di as err "maxsize() must be a positive number of GB"
        exit 198
    }
    local onlarge = lower(strtrim(`"`onlarge'"'))
    if !inlist("`onlarge'", "", "stop", "lean") {
        di as err "onlarge() must be stop or lean"
        exit 198
    }
    local profile full
    local fmts csv dta rds
    if "`lean'" != "" {
        local profile lean
        local fmts csv dta
    }
    if "`data'" == "nodata" {
        local profile nodata
        local fmts
    }
    if `"`formats'"' != "" {
        if "`data'" == "nodata" | "`lean'" != "" {
            di as err "formats() cannot be combined with lean or nodata"
            exit 198
        }
        local fmts = lower(`"`formats'"')
        foreach f of local fmts {
            if !inlist("`f'", "csv", "dta", "rds", "xlsx", "sav") {
                di as err `"formats(): `f' is not one of csv dta rds xlsx sav"'
                exit 198
            }
        }
        local fmts : list uniq fmts
        if !`: list posof "csv" in fmts' {
            di as err "formats() must include csv: the csv is the portable copy every setup script reads"
            exit 198
        }
        local profile custom
    }
    * data loaded with datadeposit use: name, version, and folder follow the parent
    local derived : char _dta[datadeposit_source]
    local prev_dir
    local prev_ds
    if `"`derived'"' != "" & `"`files'`folder'"' == "" {
        mata: _ddp_parse_prov(st_local("derived"))
        if `"`version'"' == "" & real("`prev_ver'") < . local version = real("`prev_ver'") + 1
    }
    if `"`version'"' == "" local version 1

    * ---- which datasets ------------------------------------------------------
    local filesmode = (`"`files'"' != "" | `"`folder'"' != "")
    if `"`files'"' != "" & `"`folder'"' != "" {
        di as err "files() and folder() cannot be combined"
        exit 198
    }
    if `"`pattern'"' != "" & `"`folder'"' == "" {
        di as err "pattern() requires folder()"
        exit 198
    }
    if `filesmode' & (`"`varlist'"' != "" | `"`if'"' != "" | `"`in'"' != "") {
        di as err "a varlist, if, or in applies to the data in memory; it cannot be combined with files() or folder()"
        exit 198
    }
    local srcfiles
    if `"`folder'"' != "" {
        if `"`pattern'"' == "" local pattern "*.dta"
        local found : dir `"`folder'"' files `"`pattern'"'
        local found : list sort found
        local nskip 0
        foreach f of local found {
            local ff `"`folder'/`f'"'
            mata: _ddp_sniff(st_local("ff"))
            if `sn_isdata' local srcfiles `"`srcfiles' `"`ff'"'"'
            else {
                local ++nskip
                local skip_`nskip' `"`f' (`sn_why')"'
            }
        }
        if `"`srcfiles'"' == "" {
            di as err `"no data files match `pattern' in `folder'"'
            forvalues i = 1/`nskip' {
                di as err `"  skipped `skip_`i''"'
            }
            exit 601
        }
        forvalues i = 1/`nskip' {
            di as txt `"datadeposit: skipped `skip_`i''"'
        }
    }
    else if `"`files'"' != "" {
        * files("a.dta b.dta") arrives as one quoted token; split it
        if `: word count `files'' == 1 {
            local inner : word 1 of `files'
            capture confirm file `"`inner'"'
            if _rc & strpos(`"`inner'"', " ") local files `inner'
        }
        foreach f of local files {
            local ff : subinstr local f `"""' "", all
            capture confirm file `"`ff'"'
            if _rc & lower(substr(`"`ff'"', -4, .)) != ".dta" local ff `"`ff'.dta"'
            confirm file `"`ff'"'
            mata: _ddp_sniff(st_local("ff"))
            if !`sn_isdata' {
                mata: st_local("fb", _ddp_basename(st_local("ff")))
                di as err `"`fb' is not a data file: `sn_why'"'
                exit 610
            }
            local srcfiles `"`srcfiles' `"`ff'"'"'
        }
    }
    else {
        if c(k) == 0 {
            di as err "no data in memory; load a dataset or use files()"
            exit 2000
        }
    }

    * dataset stems
    local stems
    local nds 0
    if `filesmode' {
        foreach f of local srcfiles {
            local ++nds
            mata: st_local("stem", _ddp_stem(st_local("f")))
            local stem_`nds' "`stem'"
            local src_`nds' `"`f'"'
            local stems `stems' `stem'
        }
        if `nds' == 1 & `"`name'"' != "" {
            mata: st_local("stem_1", _ddp_cleanname(st_local("name")))
            local stems `stem_1'
        }
        * two files with the same stem (a.csv and a.csv.gz): suffix the later one
        local seen
        forvalues d = 1/`nds' {
            local st `stem_`d''
            if `: list posof "`st'" in seen' {
                local k 2
                while `: list posof "`st'_`k'" in seen' | `: list posof "`st'_`k'" in stems' local ++k
                mata: st_local("fb", _ddp_basename(st_local("src_`d'")))
                di as txt "datadeposit: note: `fb' would also be named `st'; it is named `st'_`k' in the deposit"
                local stem_`d' `st'_`k'
            }
            local seen `seen' `stem_`d''
        }
        local stems `seen'
    }
    else {
        local nds 1
        if `"`name'"' != "" {
            mata: st_local("stem_1", _ddp_cleanname(st_local("name")))
        }
        else if "`prev_ds'" != "" {
            local stem_1 `prev_ds'
        }
        else if `"`c(filename)'"' != "" {
            local cfn `"`c(filename)'"'
            mata: st_local("stem_1", _ddp_stem(st_local("cfn")))
        }
        else local stem_1 data
        local src_1 `"`c(filename)'"'
        local stems `stem_1'
    }

    * target folder
    if `"`to'"' == "" {
        if `nds' > 1 {
            di as err "several datasets: say where the deposit goes with to()"
            exit 198
        }
        local base `"`src_1'"'
        mata: st_local("tdir", _ddp_dirname(st_local("base")))
        if `"`prev_dir'"' != "" {
            mata: st_local("tdir", _ddp_dirname(st_local("prev_dir")))
        }
        * data that came with Stata (sysuse, webuse) or from an ado folder: the
        * deposit goes to the working directory, never into Stata's own folders
        mata: st_local("insys", strofreal(_ddp_in_sysdir(st_local("tdir"))))
        if `insys' local tdir
        local suffix _deposit
        if "`version'" != "1" local suffix _deposit_v`version'
        if `"`tdir'"' == "" local to `"`stem_1'`suffix'"'
        else local to `"`tdir'/`stem_1'`suffix'"'
    }
    mata: st_local("absto", _ddp_abspath(st_local("to")))

    * question characteristic
    local qopt = strtrim(`"`question'"')

    * ---- size check (before anything is written) --------------------------
    local largest 0
    local largest_file
    local total_full 0
    local total_lean 0
    forvalues d = 1/`nds' {
        if `filesmode' {
            tempname EF
            frame create `EF'
            frame `EF' {
                mata: _ddp_sniff(st_local("src_`d'"))
                if inlist("`sn_kind'", "dta", "dta_old") {
                    quietly describe using `"`src_`d''"'
                    local N = r(N)
                    local W = r(width)
                    local nsamp = min(`N', 1000)
                    if `nsamp' > 0 quietly use in 1/`nsamp' using `"`src_`d''"', clear
                    else quietly use `"`src_`d''"', clear
                }
                else {
                    _ddp_load_file, file(`"`src_`d''"') quiet
                    local N = c(N)
                    local W = -1
                }
                _ddp_estimate, n(`N') width(`W')
                local est_dta_`d' = r(dta)
                local est_csv_`d' = r(csv)
            }
            frame drop `EF'
        }
        else {
            quietly count `if' `in'
            local N = r(N)
            _ddp_estimate `varlist' `if' `in', n(`N')
            local est_dta_`d' = r(dta)
            local est_csv_`d' = r(csv)
        }
        local e_csv = `est_csv_`d''
        local e_dta = `est_dta_`d''
        local total_full = `total_full' + `e_csv' + 2 * `e_dta'
        local total_lean = `total_lean' + `e_csv' + `e_dta'
        foreach f of local fmts {
            if "`f'" == "csv" local e = `e_csv'
            else if "`f'" == "xlsx" local e = 1.3 * `e_csv'
            else local e = `e_dta'
            if `e' > `largest' {
                local largest = `e'
                local largest_file "data/`stem_`d''.`f'"
            }
        }
    }
    local limit = `maxsize' * 1e9
    local size_override none
    if `largest' > `limit' & !inlist("`profile'", "lean", "nodata") {
        if "`allowlarge'" != "" {
            local size_override allowlarge
            mata: st_local("sz", _ddp_size(strtoreal(st_local("largest"))))
            di as txt "datadeposit: note: " as res "`largest_file'" as txt " will be about " ///
                as res "`sz'" as txt " (allowlarge)"
        }
        else if "`onlarge'" == "lean" {
            local size_override onlarge_lean
            local profile lean
            local fmts csv dta
            mata: st_local("sz", _ddp_size(strtoreal(st_local("largest"))))
            di as txt "datadeposit: " as res "`largest_file'" as txt " would be about " ///
                as res "`sz'" as txt ", over the " as res "`maxsize' GB" as txt ///
                " limit; onlarge(lean) switched to the lean profile (.dta + .csv + setup scripts)"
        }
        else {
            mata: st_local("sz", _ddp_size(strtoreal(st_local("largest"))))
            mata: st_local("szl", _ddp_size(strtoreal(st_local("total_lean"))))
            mata: st_local("szf", _ddp_size(strtoreal(st_local("total_full"))))
            di as err "datadeposit: " as res "`largest_file'" as err " would be about " ///
                as res "`sz'" as err ", over the " as res "`maxsize' GB" as err " limit (maxsize)."
            di as err "  Nothing was written. Choose one:"
            di as err "    lean        keep the .dta plus one .csv and the setup scripts (about `szl' in all)"
            di as err "    nodata      codebook, metadata, and setup scripts only (no data copies)"
            di as err "    allowlarge  write every format anyway (about `szf' in all)"
            di as err "  Or raise the limit with maxsize(#), or add onlarge(lean) so a deposit at the"
            di as err "  end of a do-file switches to lean by itself when the data grow."
            exit 498
        }
    }
    else if "`profile'" == "lean" & `largest' > `limit' {
        local size_override lean
    }
    local bigdata = (`largest' > 1e9)

    * ---- prepare the folder -------------------------------------------------
    local docsopt
    if `"`include'"' != "" local docsopt docs
    _ddp_prepare_target, target(`"`to'"') `replace' `docsopt'


    * ---- one pass per dataset -----------------------------------------------
    local ok_rds 1
    forvalues d = 1/`nds' {
        local ds `stem_`d''
        mata: st_local("srcbase", _ddp_basename(st_local("src_`d'")))
        if `filesmode' {
            tempname DF
            frame create `DF'
            frame `DF' {
                _ddp_load_file, file(`"`src_`d''"')
                _ddp_one, root(`"`to'"') ds(`ds') formats(`fmts') question(`"`qopt'"') ///
                    `stats' source(`"`srcbase'"') rscript(`"`rscript'"')
                local n_`d' = r(N)
                local k_`d' = r(k)
                if !r(ok_rds) local ok_rds 0
            }
            frame drop `DF'
        }
        else {
            local subset = (`"`varlist'`if'`in'"' != "")
            if `subset' {
                preserve
                if `"`if'`in'"' != "" quietly keep `if' `in'
                if `"`varlist'"' != "" keep `varlist'
            }
            capture noisily _ddp_one, root(`"`to'"') ds(`ds') formats(`fmts') question(`"`qopt'"') ///
                `stats' source(`"`srcbase'"') rscript(`"`rscript'"')
            local rc = _rc
            if !`rc' {
                local n_`d' = r(N)
                local k_`d' = r(k)
                if !r(ok_rds) local ok_rds 0
            }
            if `subset' restore
            if `rc' exit `rc'
        }
    }

    * ---- included documents -------------------------------------------------
    local ninc 0
    if `"`include'"' != "" {
        mata: _ddp_mkdirs(st_local("to") + "/docs")
    }
    foreach f of local include {
        confirm file `"`f'"'
        mata: st_local("fb", _ddp_basename(st_local("f")))
        quietly copy `"`f'"' `"`to'/docs/`fb'"', replace
        local ++ninc
    }

    * ---- deposit-level files --------------------------------------------------
    local dversion = c(stata_version)
    mata: _ddp_datapackage()
    mata: _ddp_readme()
    mata: st_local("flist", _ddp_listfiles(st_local("to")))
    local i 0
    foreach f of local flist {
        local ++i
        local h_`i'
        if "`hash'" != "nohash" {
            _ddp_sha256 `"`to'/`f'"'
            local h_`i' `r(sha256)'
        }
    }
    mata: _ddp_write_manifest()
    _ddp_sha256 `"`to'/MANIFEST.json"'
    local mhash `r(sha256)'

    * ---- verify the round trip ------------------------------------------------
    local verified "skipped"
    if "`verify'" != "noverify" & `bigdata' {
        di as txt "datadeposit: round-trip check skipped for data over 1 GB; run " ///
            as res `"datadeposit verify "`to'""' as txt " when convenient"
    }
    else if "`verify'" != "noverify" {
        local allok 1
        foreach ds of local stems {
            _ddp_roundtrip, root(`"`to'"') ds(`ds')
            if !r(ok) local allok 0
        }
        local verified = cond(`allok', "passed", "FAILED")
        if "`profile'" == "nodata" local verified "not applicable (no data files)"
    }

    * ---- receipt ---------------------------------------------------------------
    di
    di as txt "{hline 72}"
    di as txt "datadeposit wrote " as res `"`absto'"'
    di as txt "  profile " as res "`profile'" as txt ", datasets: " as res "`stems'"
    forvalues d = 1/`nds' {
        di as txt "  " as res "`stem_`d''" as txt ": " as res `n_`d'' as txt " obs, " as res `k_`d'' as txt " vars"
    }
    if "`fmts'" != "" di as txt "  data formats: " as res "`fmts'"
    if !`ok_rds' {
        di as txt "  note: no .rds was written because R (Rscript) was not found. R users can still"
        di as txt "    rebuild the data with setup/*_setup.R. To write the .rds here, install R from"
        di as txt "    https://cloud.r-project.org, or point datadeposit at it with rscript(path) or the"
        di as txt "    environment variable DATADEPOSIT_RSCRIPT. Add lean to stop asking for an .rds."
    }
    if "`mhash'" == "" & "`hash'" != "nohash" {
        di as txt "  note: no sha256 tool (shasum, sha256sum, or certutil) answered, so MANIFEST.json has"
        di as txt "    sizes but no hashes; verify still checks sizes and the round trip"
    }
    di as txt "  Stata round trip (csv + setup.do vs. the data): " as res "`verified'"
    di as txt `"  {browse `"`absto'/README.md"':README.md}   {browse `"`absto'"':open the folder}"'
    di as txt "{hline 72}"
    if "`verified'" == "FAILED" {
        di as err "datadeposit: the round-trip check found differences; see the messages above"
        exit 9
    }

    return local path `"`absto'"'
    return local datasets "`stems'"
    return local formats "`fmts'"
    return local profile "`profile'"
    return local verified "`verified'"
    return local manifest_sha256 "`mhash'"
    return scalar largest_gb = `largest' / 1e9
end

* ---------------------------------------------------------------------------
* _ddp_estimate: estimated bytes of the .dta and .csv for the data in memory
* ---------------------------------------------------------------------------
program define _ddp_estimate, rclass
    version 16
    syntax [varlist(default=none)] [if] [in] [, n(real 0) width(real -1)]
    if "`varlist'" == "" {
        quietly ds
        local varlist `r(varlist)'
    }
    tempvar sel
    quietly gen byte `sel' = 1 `if' `in'
    quietly replace `sel' = 0 if missing(`sel')
    quietly replace `sel' = 0 if sum(`sel') > 1000
    quietly count if `sel'
    local ns = r(N)
    mata: _ddp_rowwidth("`varlist'", "`sel'")
    local rw = `r_width'
    if `width' > 0 local rw = max(`rw', `width')
    return scalar dta = `n' * `rw' + 2000 * `: word count `varlist'' + 4000
    if `ns' == 0 {
        return scalar csv = 0
        exit
    }
    tempfile tf
    quietly _ddp_export_csv `varlist' using `"`tf'"' if `sel'
    mata: st_local("bytes", strofreal(_ddp_filesize(st_local("tf")), "%21.0f"))
    return scalar csv = `bytes' / `ns' * `n'
end

* ---------------------------------------------------------------------------
* _ddp_export_csv: export with formats that round-trip exactly
* ---------------------------------------------------------------------------
program define _ddp_export_csv
    version 16
    syntax [varlist(default=none)] using/ [if] [in]
    if "`varlist'" == "" {
        quietly ds
        local varlist `r(varlist)'
    }
    local j 0
    foreach v of local varlist {
        local ++j
        local f_`j' : format `v'
        local t : type `v'
        local f = subinstr("`f_`j''", "%-", "%", 1)
        if substr("`t'", 1, 3) == "str" format `v' %1s
        else if substr("`f'", 1, 3) == "%td" | (substr("`f'", 1, 2) == "%d") format `v' %tdCCYY-NN-DD
        else if substr("`f'", 1, 3) == "%tc" format `v' %tcCCYY-NN-DD_HH:MM:SS.sss
        else if substr("`f'", 1, 3) == "%tC" format `v' %tCCCYY-NN-DD_HH:MM:SS.sss
        else if "`t'" == "double" format `v' %24.17g
        else if "`t'" == "float" format `v' %16.9g
        else format `v' %20.0g
    }
    * a variable renamed for Stata keeps its original name in the csv header
    mata: st_local("hdr", _ddp_csv_header(st_local("varlist")))
    if `"`hdr'"' == "" {
        capture noisily export delimited `varlist' using `"`using'"' `if' `in', ///
            replace quote datafmt nolabel delimiter(",")
    }
    else {
        tempfile body
        capture noisily export delimited `varlist' using `"`body'"' `if' `in', ///
            replace quote datafmt nolabel delimiter(",") novarnames
        if !_rc mata: _ddp_prepend(st_local("body"), st_local("using"), st_local("hdr"))
    }
    local rc = _rc
    local j 0
    foreach v of local varlist {
        local ++j
        format `v' `f_`j''
    }
    exit `rc'
end

* ---------------------------------------------------------------------------
* _ddp_prepare_target: create the folder, or clear an earlier deposit with replace
* ---------------------------------------------------------------------------
program define _ddp_prepare_target
    version 16
    syntax , target(string) [replace docs]
    mata: st_local("isfile", strofreal(fileexists(st_local("target")) & !direxists(st_local("target"))))
    if `isfile' {
        di as err `"`target' is a file, not a folder; choose another place for the deposit"'
        exit 602
    }
    mata: st_local("exists", strofreal(direxists(st_local("target"))))
    if `exists' {
        local fl : dir `"`target'"' files "*"
        local dl : dir `"`target'"' dirs "*"
        local fl : list fl - dl
        local nonempty = (`"`fl'`dl'"' != "")
        if `nonempty' {
            if "`replace'" == "" {
                di as err `"folder `target' already exists; add replace to overwrite an earlier deposit"'
                exit 602
            }
            capture confirm file `"`target'/MANIFEST.json"'
            local ismanifest = (_rc == 0)
            if `ismanifest' {
                mata: st_local("ismanifest", strofreal(_ddp_is_deposit(st_local("target") + "/MANIFEST.json")))
            }
            if !`ismanifest' {
                di as err `"`target' is not a datadeposit folder (no MANIFEST.json written by datadeposit);"'
                di as err "  replace only overwrites earlier deposits, so nothing was deleted"
                exit 602
            }
            mata: _ddp_clear_deposit(st_local("target"))
        }
    }
    else {
        mata: _ddp_mkdirs(st_local("target"))
    }
    foreach sub in data metadata codebook setup {
        mata: _ddp_mkdirs(st_local("target") + "/" + st_local("sub"))
    }
    * mark the folder as an unfinished deposit until MANIFEST.json is written,
    * so a later run with replace can clean up after a crash
    mata: _ddp_spit(st_local("target") + "/MANIFEST.json", "{" + char(34) + "datadeposit" + char(34) + ": " + ///
        char(34) + "1.0" + char(34) + ", " + char(34) + "status" + char(34) + ": " + char(34) + "incomplete" + ///
        char(34) + ", " + char(34) + "files" + char(34) + ": []}" + char(10))
    if "`docs'" != "" {
        mata: _ddp_mkdirs(st_local("target") + "/docs")
    }
end

* ---------------------------------------------------------------------------
* _ddp_one: write every file for the dataset in the current frame
* ---------------------------------------------------------------------------
program define _ddp_one, rclass
    version 16
    syntax , root(string) ds(string) [formats(string) question(string) ///
        nostats source(string) rscript(string)]

    * a strL holding binary bytes (a stored file) cannot travel through a csv
    mata: st_local("binvars", _ddp_binary_vars())
    if "`binvars'" != "" {
        di as err "datadeposit: `binvars' hold(s) binary data (for example a file stored in a strL);"
        di as err "  a csv cannot carry it. Drop the variable, or save the files it holds and pass them with include()."
        exit 459
    }
    * datadeposit's own provenance mark is recorded in MANIFEST.json, not in the data
    local prov : char _dta[datadeposit_source]
    char _dta[datadeposit_source]

    * value label sets that save keeps: attached ones and label-language ones
    quietly label dir
    local defined `r(names)'
    mata: st_local("sets", _ddp_used_sets(st_local("defined")))
    local dlab : data label
    local sortedby : sortedby
    local qchar `"`question'"'
    if `"`qchar'"' == "" {
        mata: st_local("qchar", _ddp_find_qchar())
    }
    capture noisily {
        mata: _ddp_extract(st_local("root"), st_local("ds"), st_local("qchar"), ///
            st_local("sets"), st_local("dlab"), st_local("sortedby"), st_local("source"), 1)
        if "`stats'" != "nostats" {
            mata: _ddp_stats(st_local("root"), st_local("ds"))
        }
        foreach lang in do R py {
            mata: _ddp_write_template(st_local("root"), st_local("ds"), st_local("lang"))
        }
        local okr 1
        foreach f of local formats {
            if "`f'" == "csv" {
                quietly _ddp_export_csv using `"`root'/data/`ds'.csv"'
            }
            else if "`f'" == "dta" {
                quietly save `"`root'/data/`ds'.dta"', replace
            }
            else if "`f'" == "xlsx" {
                if c(N) > 1048575 {
                    di as txt "datadeposit: note: `ds' has more rows than Excel allows; no .xlsx copy written"
                }
                else {
                    tempfile dxt
                    quietly export excel using `"`dxt'.xlsx"', sheet("codes") firstrow(variables) nolabel replace
                    quietly export excel using `"`dxt'.xlsx"', sheet("labels") firstrow(variables) sheetreplace
                    quietly copy `"`dxt'.xlsx"' `"`root'/data/`ds'.xlsx"', replace
                    erase `"`dxt'.xlsx"'
                }
            }
        }
        foreach f in rds sav {
            if `: list posof "`f'" in formats' {
                _ddp_rengine, root(`"`root'"') ds(`ds') format(`f') rscript(`"`rscript'"')
                if !r(ok) local okr 0
            }
        }
        mata: _ddp_codebook_md(st_local("root"), st_local("ds"))
        mata: _ddp_ddi(st_local("root"), st_local("ds"))
        _ddp_codebook_xlsx, root(`"`root'"') ds(`ds')
    }
    local rc = _rc
    if `"`prov'"' != "" {
        mata: st_global("_dta[datadeposit_source]", st_local("prov"))
    }
    if `rc' exit `rc'
    return scalar N = c(N)
    return scalar k = c(k)
    return scalar ok_rds = `okr'
end

* ---------------------------------------------------------------------------
* _ddp_rengine: build .rds or .sav by running the deposit's own setup.R
* ---------------------------------------------------------------------------
program define _ddp_rengine, rclass
    version 16
    syntax , root(string) ds(string) format(string) [rscript(string)]
    _ddp_find_rscript, rscript(`"`rscript'"')
    local rs `"`r(rscript)'"'
    if `"`rs'"' == "" {
        return scalar ok = 0
        exit
    }
    local out `"`root'/data/`ds'.`format'"'
    capture erase `"`out'"'
    tempfile rlog
    local flag = cond("`format'" == "rds", "--save-rds", "--save-sav")
    local cmd `""`rs'" "`root'/setup/`ds'_setup.R" --root "`root'" `flag' "`out'" > "`rlog'" 2>&1"'
    if c(os) == "Windows" local cmd `"cmd /c "`cmd'""'
    quietly shell `cmd'
    capture confirm file `"`out'"'
    if _rc {
        di as txt "datadeposit: note: Rscript did not write `ds'.`format'; its messages:"
        capture noisily type `"`rlog'"'
        return scalar ok = 0
        exit
    }
    return scalar ok = 1
end

program define _ddp_find_rscript, rclass
    version 16
    syntax [, rscript(string)]
    local envr : env DATADEPOSIT_RSCRIPT
    if lower(`"`rscript'"') == "none" | lower(`"`envr'"') == "none" {
        return local rscript ""
        exit
    }
    local cands `"`"`rscript'"' `"`envr'"'"'
    if c(os) == "Windows" {
        local rdirs : dir "C:/Program Files/R" dirs "R-*"
        local rdirs : list sort rdirs
        local nr : word count `rdirs'
        forvalues i = `nr'(-1)1 {
            local rd : word `i' of `rdirs'
            local cands `"`cands' `"C:/Program Files/R/`rd'/bin/Rscript.exe"'"'
        }
    }
    else {
        local cands `"`cands' "/opt/homebrew/bin/Rscript" "/usr/local/bin/Rscript" "/usr/bin/Rscript""'
        local cands `"`cands' "/Library/Frameworks/R.framework/Resources/bin/Rscript""'
    }
    * a candidate counts only if it runs: shell never reports exit codes, so
    * the test is whether Rscript wrote the expected text
    * (exit inside foreach does not leave the program, so record and break)
    tempfile probe
    local found
    foreach c of local cands {
        if `"`c'"' == "" continue
        capture erase `"`probe'"'
        quietly shell "`c'" -e "cat('datadeposit-ok')" > "`probe'" 2>/dev/null
        capture confirm file `"`probe'"'
        if _rc continue
        mata: st_local("pok", strofreal(strpos(_ddp_slurp(st_local("probe")), "datadeposit-ok") > 0))
        if `pok' {
            local found `"`c'"'
            continue, break
        }
    }
    return local rscript `"`found'"'
end

* ---------------------------------------------------------------------------
* _ddp_codebook_xlsx: the metadata tables as Excel sheets
* ---------------------------------------------------------------------------
program define _ddp_codebook_xlsx
    version 16
    syntax , root(string) ds(string)
    * export excel cannot reopen a workbook in a folder whose name has accented
    * letters, so build it under an ASCII temporary name and copy it into place
    local xldest `"`root'/codebook/`ds'_codebook.xlsx"'
    capture erase `"`xldest'"'
    tempfile xlt
    local xl `"`xlt'.xlsx"'
    tempname XF
    frame create `XF'
    local first 1
    foreach tab in variables valuelabels chars dataset summary frequencies {
        capture confirm file `"`root'/metadata/`ds'_`tab'.csv"'
        if _rc continue
        frame `XF' {
            quietly import delimited using `"`root'/metadata/`ds'_`tab'.csv"', varnames(1) ///
                case(preserve) encoding("utf-8") bindquotes(strict) stringcols(_all) ///
                maxquotedrows(unlimited) delimiters(",") clear
            * Excel holds at most 32,767 characters in a cell
            foreach v of varlist _all {
                local vt : type `v'
                if "`vt'" == "strL" {
                    quietly replace `v' = usubstr(`v', 1, 32000) + ///
                        " [cut for Excel; full text in metadata/`ds'_`tab'.csv]" if strlen(`v') > 32000
                }
            }
            if c(N) == 0 quietly set obs 1
            if `first' quietly export excel using `"`xl'"', sheet("`tab'") firstrow(variables) replace
            else quietly export excel using `"`xl'"', sheet("`tab'") firstrow(variables) sheetreplace
        }
        local first 0
    }
    frame drop `XF'
    capture confirm file `"`xl'"'
    if !_rc {
        quietly copy `"`xl'"' `"`xldest'"', replace
        erase `"`xl'"'
    }
end

* ---------------------------------------------------------------------------
* _ddp_manifest: hash every file and write MANIFEST.json
* ---------------------------------------------------------------------------
program define _ddp_sha256, rclass
    version 16
    args file
    tempfile out
    if c(os) == "Windows" {
        quietly shell certutil -hashfile "`file'" SHA256 > "`out'"
    }
    else {
        quietly shell (sha256sum "`file'" 2>/dev/null || shasum -a 256 "`file'") > "`out'" 2>/dev/null
    }
    mata: st_local("h", _ddp_parse_hash(st_local("out")))
    return local sha256 "`h'"
end

* ---------------------------------------------------------------------------
* _ddp_roundtrip: rebuild from the csv with setup.do and compare
* ---------------------------------------------------------------------------
program define _ddp_roundtrip, rclass
    version 16
    syntax , root(string) ds(string) [quiet]
    local ok 1
    tempname RF CF
    tempfile tdir
    local tdir `"`tdir'_rt"'
    mata: _ddp_mkdirs(st_local("tdir") + "/metadata")
    mata: st_local("q_ds", _ddp_dskey(st_local("root"), st_local("ds"), "question_char"))
    mata: st_local("src_ds", _ddp_dskey(st_local("root"), st_local("ds"), "source_file"))
    capture confirm file `"`root'/data/`ds'.csv"'
    local hascsv = !_rc
    if `hascsv' {
        frame create `RF'
        capture frame `RF' {
            quietly do `"`root'/setup/`ds'_setup.do"' `"`root'"'
        }
        if _rc {
            di as err "round trip: setup/`ds'_setup.do failed (r(" _rc "))"
            capture frame drop `RF'
            return scalar ok = 0
            exit
        }
        frame `RF' {
            quietly label dir
            local sets `r(names)'
            local dlab : data label
            local sortedby : sortedby
            mata: _ddp_extract(st_local("tdir"), st_local("ds"), st_local("q_ds"), ///
                st_local("sets"), st_local("dlab"), st_local("sortedby"), st_local("src_ds"), 0)
        }
        foreach tab in variables valuelabels chars dataset {
            mata: st_local("same", strofreal(_ddp_samefile(st_local("root") + "/metadata/" + ///
                st_local("ds") + "_" + st_local("tab") + ".csv", st_local("tdir") + "/metadata/" + ///
                st_local("ds") + "_" + st_local("tab") + ".csv")))
            if !`same' {
                di as err "round trip: `ds'_`tab'.csv rebuilt from the csv differs from the deposit"
                local ok 0
            }
        }
        capture confirm file `"`root'/data/`ds'.dta"'
        if !_rc {
            frame `RF': capture cf _all using `"`root'/data/`ds'.dta"', all
            if _rc {
                * Stata's import delimited drops a carriage return inside quoted
                * text; R and Python keep it. Tell that apart from real damage.
                tempname CR
                tempfile nocr
                frame create `CR'
                frame `CR' {
                    quietly use `"`root'/data/`ds'.dta"', clear
                    local ncr 0
                    foreach v of varlist _all {
                        capture confirm string variable `v'
                        if _rc continue
                        quietly count if strpos(subinstr(`v', char(13) + char(10), "", .), char(13))
                        local ncr = `ncr' + r(N)
                        quietly replace `v' = subinstr(subinstr(`v', char(13) + char(10), char(13), .), ///
                            char(13), char(13) + char(10), .)
                    }
                    quietly save `"`nocr'"'
                }
                frame drop `CR'
                frame `RF': capture cf _all using `"`nocr'"', all
                if _rc | `ncr' == 0 {
                    di as err "round trip: values rebuilt from the csv differ from data/`ds'.dta"
                    local ok 0
                }
                else {
                    di as txt "round trip note: `ncr' text value(s) in `ds' hold a lone carriage return;"
                    di as txt "  Stata's csv import cannot keep one, so setup.do returns it as a Windows line break."
                    di as txt "  The .dta, the csv, and the R and Python setup scripts keep the original."
                }
            }
        }
        frame drop `RF'
    }
    capture confirm file `"`root'/data/`ds'.dta"'
    if !_rc {
        frame create `CF'
        frame `CF' {
            quietly use `"`root'/data/`ds'.dta"', clear
            quietly label dir
            local sets `r(names)'
            local dlab : data label
            local sortedby : sortedby
            mata: _ddp_extract(st_local("tdir"), st_local("ds"), st_local("q_ds"), ///
                st_local("sets"), st_local("dlab"), st_local("sortedby"), st_local("src_ds"), 0)
        }
        frame drop `CF'
        foreach tab in variables valuelabels chars dataset {
            mata: st_local("same", strofreal(_ddp_samefile(st_local("root") + "/metadata/" + ///
                st_local("ds") + "_" + st_local("tab") + ".csv", st_local("tdir") + "/metadata/" + ///
                st_local("ds") + "_" + st_local("tab") + ".csv")))
            if !`same' {
                di as err "check: data/`ds'.dta metadata differs from metadata/`ds'_`tab'.csv"
                local ok 0
            }
        }
    }
    return scalar ok = `ok'
end

* ---------------------------------------------------------------------------
* _ddp_load_file: load any data file, recognized by content (see sniff.py)
* ---------------------------------------------------------------------------
program define _ddp_load_file, rclass
    version 16
    syntax , file(string) [quiet]
    mata: _ddp_sniff(st_local("file"))
    mata: st_local("base", _ddp_basename(st_local("file")))
    local ext = lower(substr(`"`base'"', strrpos(`"`base'"', ".") + 1, .))
    local nn 0
    if "`sn_kind'" == "dta" & "`ext'" != "dta" {
        local ++nn
        local note_`nn' "`base' is really a dta file; read it as one"
    }
    if inlist("`sn_kind'", "dta", "dta_old") {
        quietly use `"`file'"', clear
    }
    else if "`sn_kind'" == "sav" {
        quietly import spss using `"`file'"', clear
    }
    else if inlist("`sn_kind'", "xlsx", "xls") {
        quietly import excel using `"`file'"', describe
        local nsh = r(N_worksheet)
        local sh1 `"`r(worksheet_1)'"'
        quietly import excel using `"`file'"', allstring clear
        if `nsh' > 1 {
            local ++nn
            local note_`nn' `"`base' has `nsh' sheets; only the first (`sh1') was deposited"'
        }
        mata: _ddp_header_from_row1()
        _ddp_type_text, decimal(".") base(`"`base'"')
        local ++nn
        local note_`nn' `"`r(note)'"'
    }
    else if inlist("`sn_kind'", "delimited", "gzip") {
        local src `"`file'"'
        if "`sn_kind'" == "gzip" {
            tempfile gz
            if c(os) == "Windows" {
                di as err "`base' is compressed; unzip it first (Stata on Windows has no gunzip)"
                exit 610
            }
            quietly shell gunzip -c "`file'" > "`gz'"
            capture confirm file `"`gz'"'
            if _rc {
                di as err "`base' is compressed and gunzip could not open it; unzip it first"
                exit 610
            }
            mata: _ddp_sniff(st_local("gz"))
            if "`sn_kind'" != "delimited" {
                di as err "`base' is compressed, and what it holds is not a delimited table: `sn_why'"
                exit 610
            }
            local src `"`gz'"'
        }
        if "`sn_enc'" == "utf-16" {
            tempfile u8
            mata: _ddp_utf16_to_utf8(st_local("src"), st_local("u8"))
            local src `"`u8'"'
            local sn_enc "utf-8"
            local ++nn
            local note_`nn' "`base' is UTF-16 text; it was converted to UTF-8"
        }
        local dopt `"delimiters("`sn_delim'")"'
        if "`sn_delim'" == "tab" local dopt "delimiters(tab)"
        quietly import delimited using `"`src'"', `dopt' varnames(nonames) encoding("`sn_enc'") ///
            bindquotes(strict) maxquotedrows(unlimited) stringcols(_all) clear
        mata: _ddp_header_from_row1()
        if `"`hdr_note'"' != "" {
            local ++nn
            local note_`nn' `"`base' `hdr_note'"'
        }
        if "`sn_enc'" == "latin1" {
            local ++nn
            local note_`nn' "`base' is not UTF-8; it was read as Latin-1 (Windows-1252) and the deposit is UTF-8"
        }
        if "`sn_delim'" != "," {
            local dname = cond("`sn_delim'" == "tab", "a tab", "'`sn_delim''")
            local ++nn
            local note_`nn' "`base' is delimited by `dname'; the deposit's csv uses commas"
        }
        if "`sn_dec'" == "," {
            local ++nn
            local note_`nn' "`base' writes decimals with a comma; numbers were read that way"
        }
        _ddp_type_text, decimal("`sn_dec'") base(`"`base'"')
        local ++nn
        local note_`nn' `"`r(note)'"'
    }
    else {
        di as err `"`base': cannot read files of type `sn_kind' in Stata"'
        exit 610
    }
    if "`quiet'" == "" {
        forvalues i = 1/`nn' {
            if `"`note_`i''"' != "" di as txt `"datadeposit: note: `note_`i''"'
        }
    }
end

* text columns become numbers only when every value is a number and none
* has a leading zero; NA-style tokens count as missing (rules shared with R and Python)
program define _ddp_type_text, rclass
    version 16
    syntax , decimal(string) base(string)
    local kept
    local natok
    local order
    foreach v of varlist _all {
        local order `order' `v'
    }
    foreach v of local order {
        mata: _ddp_typecheck(st_local("v"), st_local("decimal"))
        if `tc_num' {
            tempvar t
            if "`decimal'" == "," {
                quietly gen double `t' = real(subinstr(strtrim(`v'), ",", ".", .))
            }
            else quietly gen double `t' = real(strtrim(`v'))
            quietly replace `t' = . if inlist(strtrim(`v'), "", "NA", "N/A", "NaN", "nan", "null", "NULL", ".")
            local lab : variable label `v'
            local dn : char `v'[datadeposit_name]
            drop `v'
            rename `t' `v'
            if `"`dn'"' != "" char `v'[datadeposit_name] `"`dn'"'
            quietly recast `tc_type' `v', force
            format `v' `tc_fmt'
            if `tc_natok' local natok `natok' `v'
        }
        else {
            if "`tc_type'" == "strL" quietly recast strL `v'
            else {
                capture quietly recast `tc_type' `v'
            }
            format `v' `tc_fmt'
            if `tc_lead0' local kept `kept' `v'
        }
    }
    order `order'
    local note
    if "`kept'" != "" local note "`base': `kept' kept as text because values start with 0 (for example ZIP codes or IDs)"
    if "`natok'" != "" {
        if "`note'" != "" local note "`note'; "
        local note "`note'`base': NA, N/A, NaN, null, or . read as missing in the numeric column(s) `natok'"
    }
    return local note `"`note'"'
end

* ===========================================================================
* use
* ===========================================================================
program define _ddp_use, rclass
    version 16
    syntax anything(name=dep) [, clear name(string) csv]
    local dep `dep'
    if c(changed) & "`clear'" == "" {
        di as err "no; data in memory would be lost (add clear)"
        exit 4
    }
    capture confirm file `"`dep'/MANIFEST.json"'
    if _rc {
        di as err `"`dep' is not a datadeposit folder (no MANIFEST.json)"'
        exit 601
    }
    mata: st_local("unfin", strofreal(strpos(_ddp_slurp(st_local("dep") + "/MANIFEST.json"), "incomplete") > 0))
    if `unfin' {
        di as err `"the deposit in `dep' did not finish; run datadeposit again with replace"'
        exit 601
    }
    local vfiles : dir `"`dep'/metadata"' files "*_variables.csv"
    local stems
    foreach f of local vfiles {
        local stems `stems' `=substr("`f'", 1, strlen("`f'") - 14)'
    }
    local stems : list sort stems
    if `"`name'"' == "" {
        if `: word count `stems'' > 1 {
            di as err "this deposit holds several datasets (`stems'); pick one with name()"
            exit 198
        }
        local ds `stems'
    }
    else {
        local ds `name'
        if !`: list posof "`ds'" in stems' {
            di as err "dataset `ds' is not in this deposit (it holds: `stems')"
            exit 111
        }
    }
    capture confirm file `"`dep'/data/`ds'.dta"'
    if !_rc & "`csv'" == "" {
        quietly use `"`dep'/data/`ds'.dta"', clear
        local how "data/`ds'.dta"
    }
    else {
        quietly do `"`dep'/setup/`ds'_setup.do"' `"`dep'"'
        local how "data/`ds'.csv through setup/`ds'_setup.do"
    }
    mata: st_local("absdep", _ddp_abspath(st_local("dep")))
    mata: st_local("dver", _ddp_manifest_key(st_local("dep") + "/MANIFEST.json", "version"))
    _ddp_sha256 `"`dep'/MANIFEST.json"'
    local mh `r(sha256)'
    mata: st_global("_dta[datadeposit_source]", st_local("absdep") + "|" + st_local("dver") + "|" + st_local("mh") + "|" + st_local("ds"))
    di as txt "datadeposit: loaded " as res "`ds'" as txt " (" as res c(N) as txt " obs, " ///
        as res c(k) as txt " vars) from " as res "`how'"
    di as txt "  deposit version " as res "`dver'" as txt "; a new deposit made from these data records it as the parent"
    return local dataset "`ds'"
    return local source "`how'"
    return local deposit `"`absdep'"'
    return local version "`dver'"
end

* ===========================================================================
* verify
* ===========================================================================
program define _ddp_verify, rclass
    version 16
    syntax anything(name=dep) [, nohash]
    local dep `dep'
    capture confirm file `"`dep'/MANIFEST.json"'
    if _rc {
        di as err `"`dep' is not a datadeposit folder (no MANIFEST.json)"'
        exit 601
    }
    mata: st_local("unfin", strofreal(strpos(_ddp_slurp(st_local("dep") + "/MANIFEST.json"), "incomplete") > 0))
    if `unfin' {
        di as err `"the deposit in `dep' did not finish; run datadeposit again with replace"'
        exit 601
    }
    mata: _ddp_read_manifest(st_local("dep") + "/MANIFEST.json")
    local bad 0
    forvalues i = 1/`m_n' {
        local f `"`m_path_`i''"'
        capture confirm file `"`dep'/`f'"'
        if _rc {
            di as err "missing: `f'"
            local ++bad
            continue
        }
        mata: st_local("b", strofreal(_ddp_filesize(st_local("dep") + "/" + st_local("f")), "%21.0f"))
        if "`b'" != "`m_bytes_`i''" {
            di as err "size changed: `f' (`b' bytes; manifest says `m_bytes_`i'')"
            local ++bad
            continue
        }
        if "`hash'" != "nohash" & "`m_sha_`i''" != "" {
            _ddp_sha256 `"`dep'/`f'"'
            if "`r(sha256)'" != "`m_sha_`i''" {
                di as err "content changed: `f' (sha256 differs)"
                local ++bad
            }
        }
    }
    di as txt "files: " as res `m_n' as txt " checked, " as res `bad' as txt " problems"
    local vfiles : dir `"`dep'/metadata"' files "*_variables.csv"
    local rtok 1
    foreach f of local vfiles {
        local ds = substr("`f'", 1, strlen("`f'") - 14)
        _ddp_roundtrip, root(`"`dep'"') ds(`ds')
        if !r(ok) local rtok 0
        di as txt "round trip `ds': " as res cond(r(ok), "passed", "FAILED")
    }
    return scalar files_bad = `bad'
    return scalar roundtrip_ok = `rtok'
    return scalar ok = (`bad' == 0 & `rtok')
    if `bad' | !`rtok' {
        di as err "datadeposit verify: problems found"
        exit 9
    }
    di as txt "datadeposit verify: all checks passed"
end

* ===========================================================================
* apply: put edited metadata tables back on the data in memory
* ===========================================================================
program define _ddp_apply, rclass
    version 16
    syntax using/ [, name(string) types nochars]
    local src `"`using'"'
    tempname AV AL AC
    local isx = lower(substr(`"`src'"', -5, .)) == ".xlsx"
    if `isx' {
        foreach pair in "`AV' variables" "`AL' valuelabels" "`AC' chars" {
            gettoken fr tab : pair
            local tab = strtrim("`tab'")
            frame create `fr'
            frame `fr': capture quietly import excel using `"`src'"', sheet("`tab'") firstrow allstring clear
            if _rc & "`tab'" == "variables" {
                di as err `"`src' has no sheet named variables"'
                exit 198
            }
        }
    }
    else {
        local mdir `"`src'"'
        local hasmeta : dir `"`src'"' dirs "metadata"
        if `"`hasmeta'"' != "" local mdir `"`src'/metadata"'
        local vfiles : dir `"`mdir'"' files "*_variables.csv"
        local nv : word count `vfiles'
        if `nv' == 0 {
            di as err `"no *_variables.csv found in `mdir'"'
            exit 601
        }
        if `"`name'"' == "" {
            if `nv' > 1 {
                di as err "several datasets here; pick one with name()"
                exit 198
            }
            local f : word 1 of `vfiles'
            local name = substr("`f'", 1, strlen("`f'") - 14)
        }
        foreach pair in "`AV' variables" "`AL' valuelabels" "`AC' chars" {
            gettoken fr tab : pair
            local tab = strtrim("`tab'")
            frame create `fr'
            capture confirm file `"`mdir'/`name'_`tab'.csv"'
            if !_rc {
                frame `fr': quietly import delimited using `"`mdir'/`name'_`tab'.csv"', varnames(1) ///
                    case(preserve) encoding("utf-8") bindquotes(strict) stringcols(_all) ///
                    maxquotedrows(unlimited) delimiters(",") clear
            }
        }
    }
    local vab = c(varabbrev)
    set varabbrev off
    capture noisily _ddp_apply_core, fv(`AV') fl(`AL') fc(`AC') `types' `chars'
    local rc = _rc
    set varabbrev `vab'
    foreach fr in `AV' `AL' `AC' {
        capture frame drop `fr'
    }
    if `rc' exit `rc'
    return add
end

program define _ddp_apply_core, rclass
    version 16
    syntax , fv(name) fl(name) fc(name) [types nochars]
    local napplied 0
    local missing
    local drops
    local renames
    frame `fv' {
        local nrow = _N
        capture confirm variable stata_name
        local namevar = cond(_rc, "name", "stata_name")
        capture confirm variable new_name
        local hasnew = !_rc
        capture confirm variable drop
        local hasdrop = !_rc
    }
    * value label sets named in the table are rebuilt from scratch
    frame `fl' {
        local NL = _N
        local lsets
        if `NL' {
            capture confirm variable set
            if !_rc {
                quietly levelsof set, local(lsets) clean
            }
        }
    }
    foreach s of local lsets {
        capture label drop `s'
    }
    forvalues i = 1/`NL' {
        local set = _frval(`fl', set, `i')
        local val = _frval(`fl', value, `i')
        local txt = _frval(`fl', label, `i')
        mata: st_vlmodify(st_local("set"), strtoreal(st_local("val")), st_local("txt"))
    }
    forvalues i = 1/`nrow' {
        local v = _frval(`fv', `namevar', `i')
        capture confirm variable `v', exact
        if _rc {
            local missing `missing' `v'
            continue
        }
        local ++napplied
        local lab = _frval(`fv', label, `i')
        mata: st_varlabel(st_local("v"), usubstr(st_local("lab"), 1, 80))
        mata: st_local("llen", strofreal(ustrlen(st_local("lab"))))
        if `llen' > 80 {
            mata: st_global(st_local("v") + "[datadeposit_label]", st_local("lab"))
        }
        capture local fmt = _frval(`fv', format, `i')
        if !_rc & "`fmt'" != "" capture format `v' `fmt'
        capture local vl = _frval(`fv', value_labels, `i')
        if !_rc {
            if "`vl'" != "" capture label values `v' `vl'
            else capture label values `v'
        }
        if "`types'" != "" {
            local typ = _frval(`fv', stata_type, `i')
            if "`typ'" == "float" quietly recast float `v', force
            else quietly recast `typ' `v'
        }
        if `hasdrop' {
            local dr = strtrim(_frval(`fv', drop, `i'))
            if inlist("`dr'", "1", "yes", "y", "x", "true") local drops `drops' `v'
        }
        if `hasnew' {
            local nn = strtrim(_frval(`fv', new_name, `i'))
            if "`nn'" != "" & "`nn'" != "`v'" {
                confirm name `nn'
                local renames `renames' `v' `nn'
            }
        }
    }
    local nchars 0
    if "`chars'" != "nochars" {
        frame `fc': local NC = _N
        forvalues i = 1/`NC' {
            local cv  = _frval(`fc', variable, `i')
            local cn  = _frval(`fc', char, `i')
            local txt = _frval(`fc', text, `i')
            if "`cv'" != "_dta" {
                capture confirm variable `cv', exact
                if _rc continue
            }
            mata: st_local("cut", strofreal(strpos(st_local("txt"), "[cut for Excel; full text in") > 0))
            if `cut' continue
            mata: st_global(st_local("cv") + "[" + st_local("cn") + "]", st_local("txt"))
            local ++nchars
        }
    }
    if "`drops'" != "" drop `drops'
    while "`renames'" != "" {
        gettoken a renames : renames
        gettoken b renames : renames
        rename `a' `b'
    }
    quietly ds
    local inmem `r(varlist)'
    di as txt "datadeposit apply: " as res `napplied' as txt " variables updated, " ///
        as res `NL' as txt " value labels, " as res `nchars' as txt " characteristics"
    if "`missing'" != "" di as txt "  in the table but not in the data: " as res "`missing'"
    if "`drops'" != "" di as txt "  dropped: " as res "`drops'"
    return scalar n_applied = `napplied'
    return local not_found "`missing'"
    return local dropped "`drops'"
end

* ===========================================================================
* Mata
* ===========================================================================
version 14
mata:

string scalar _ddp_qt(string scalar s)
{
    string scalar d
    d = char(34)
    return(d + subinstr(s, d, d + d) + d)
}

void _ddp_writecsv(string scalar path, string matrix M)
{
    real scalar fh, i, j
    string scalar line
    if (fileexists(path)) unlink(path)
    fh = fopen(path, "w")
    for (i = 1; i <= rows(M); i++) {
        line = ""
        for (j = 1; j <= cols(M); j++) {
            line = line + (j > 1 ? "," : "") + _ddp_qt(M[i, j])
        }
        fwrite(fh, line + char(10))
    }
    fclose(fh)
}

string scalar _ddp_slurp(string scalar path)
{
    real scalar fh, n
    string scalar s
    fh = fopen(path, "r")
    fseek(fh, 0, 1)
    n = ftell(fh)
    fseek(fh, 0, -1)
    s = (n > 0 ? fread(fh, n) : "")
    fclose(fh)
    return(s)
}

void _ddp_spit(string scalar path, string scalar s)
{
    real scalar fh
    if (fileexists(path)) unlink(path)
    fh = fopen(path, "w")
    if (strlen(s)) fwrite(fh, s)
    fclose(fh)
}

real scalar _ddp_filesize(string scalar path)
{
    real scalar fh, n
    fh = _fopen(path, "r")
    if (fh < 0) return(.)
    fseek(fh, 0, 1)
    n = ftell(fh)
    fclose(fh)
    return(n)
}

real scalar _ddp_samefile(string scalar a, string scalar b)
{
    if (!fileexists(a) | !fileexists(b)) return(0)
    return(_ddp_slurp(a) == _ddp_slurp(b))
}

// RFC 4180 reader; returns all rows including the header
string matrix _ddp_readcsv(string scalar path)
{
    string scalar s, field
    real rowvector b
    real scalar n, i, start, nr, nc, r, c, inq
    string matrix M
    s = _ddp_slurp(path)
    n = strlen(s)
    if (n == 0) return(J(0, 0, ""))
    b = ascii(s)
    // pass 1: count rows and columns of the header
    nr = 0
    nc = 1
    inq = 0
    for (i = 1; i <= n; i++) {
        if (b[i] == 34) inq = !inq
        else if (!inq & b[i] == 10) nr++
        else if (!inq & b[i] == 44 & nr == 0) nc++
    }
    if (b[n] != 10) nr++
    M = J(nr, nc, "")
    r = 1
    c = 1
    i = 1
    while (i <= n) {
        if (b[i] == 34) {
            i++
            start = i
            field = ""
            while (i <= n) {
                if (b[i] == 34) {
                    if (i < n) {
                        if (b[i + 1] == 34) {
                            field = field + substr(s, start, i - start + 1)
                            i = i + 2
                            start = i
                            continue
                        }
                    }
                    field = field + substr(s, start, i - start)
                    i++
                    break
                }
                i++
            }
        }
        else {
            start = i
            while (i <= n) {
                if (b[i] == 44 | b[i] == 10 | b[i] == 13) break
                i++
            }
            field = substr(s, start, i - start)
        }
        if (c <= nc & r <= nr) M[r, c] = field
        if (i > n) break
        if (b[i] == 44) {
            c++
            i++
            continue
        }
        if (b[i] == 13) i++
        if (i <= n) {
            if (b[i] == 10) i++
        }
        r++
        c = 1
    }
    return(M)
}

// column of a table by header name
string colvector _ddp_col(string matrix M, string scalar nm)
{
    real scalar j
    for (j = 1; j <= cols(M); j++) {
        if (M[1, j] == nm) return(rows(M) > 1 ? M[|2, j \ rows(M), j|] : J(0, 1, ""))
    }
    return(J(max((rows(M) - 1, 0)), 1, ""))
}

string scalar _ddp_meta(string scalar root, string scalar ds, string scalar tab)
{
    return(root + "/metadata/" + ds + "_" + tab + ".csv")
}

string scalar _ddp_dskey(string scalar root, string scalar ds, string scalar key)
{
    string matrix D
    string colvector k, v
    real scalar i
    D = _ddp_readcsv(_ddp_meta(root, ds, "dataset"))
    k = _ddp_col(D, "key")
    v = _ddp_col(D, "value")
    for (i = 1; i <= rows(k); i++) if (k[i] == key) return(v[i])
    return("")
}

string scalar _ddp_kind(string scalar typ, string scalar fmt)
{
    string scalar f
    if (substr(typ, 1, 3) == "str") return("string")
    f = subinstr(fmt, "%-", "%", 1)
    if (substr(f, 1, 3) == "%td" | substr(f, 1, 2) == "%d") return("date")
    if (substr(f, 1, 3) == "%tc" | substr(f, 1, 3) == "%tC") return("datetime")
    return("numeric")
}

string scalar _ddp_vfmt(real scalar v)
{
    if (v >= .) return(strofreal(v))
    if (v == floor(v)) return(strtrim(strofreal(v, "%21.0f")))
    return(_ddp_fmtnum(v))
}

// integers below 1e15 in full; everything else as C printf %.10g
string scalar _ddp_fmtnum(real scalar x)
{
    string scalar e, m, f
    real scalar X, p
    if (x >= .) return(x == . ? "" : strofreal(x))
    if (x == 0) return("0")
    if (x == floor(x) & abs(x) < 1e15) return(strtrim(strofreal(x, "%21.0f")))
    e = strtrim(strofreal(x, "%24.9e"))
    p = strpos(e, "e")
    X = strtoreal(substr(e, p + 1, .))
    if (X >= -4 & X < 10) {
        f = strtrim(strofreal(x, "%32." + strofreal(9 - X) + "f"))
        return(_ddp_stripzeros(f))
    }
    m = _ddp_stripzeros(substr(e, 1, p - 1))
    return(m + substr(e, p, .))
}

string scalar _ddp_stripzeros(string scalar f0)
{
    string scalar f
    f = f0
    if (!strpos(f, ".")) return(f)
    while (substr(f, strlen(f), 1) == "0") f = substr(f, 1, strlen(f) - 1)
    if (substr(f, strlen(f), 1) == ".") f = substr(f, 1, strlen(f) - 1)
    return(f)
}

string scalar _ddp_used_sets(string scalar defined)
{
    string rowvector def
    string matrix used
    string colvector names
    real colvector keep
    real scalar k, j
    def = tokens(defined)
    used = J(1, 0, "")
    for (k = 1; k <= st_nvar(); k++) {
        if (st_varvaluelabel(k) != "") used = used, st_varvaluelabel(k)
        names = st_dir("char", st_varname(k), "_lang_l_*")
        for (j = 1; j <= rows(names); j++) used = used, st_global(st_varname(k) + "[" + names[j] + "]")
    }
    if (!cols(used) | !cols(def)) return("")
    used = uniqrows(used')
    keep = J(rows(used), 1, 0)
    for (k = 1; k <= rows(used); k++) {
        for (j = 1; j <= cols(def); j++) if (used[k] == def[j]) keep[k] = 1
    }
    if (!any(keep)) return("")
    return(invtokens(select(used, keep)'))
}

// the csv header when some variable has an original name (else "")
string scalar _ddp_csv_header(string scalar vlist)
{
    string rowvector v
    string scalar h, nm, f
    real scalar k, any
    v = tokens(vlist)
    h = ""
    any = 0
    for (k = 1; k <= cols(v); k++) {
        nm = st_global(v[k] + "[datadeposit_name]")
        if (nm == "") nm = v[k]
        else any = 1
        f = nm
        if (strpos(f, ",") | strpos(f, char(34)) | strpos(f, char(10)) | strpos(f, char(13)) | f != strtrim(f)) {
            f = char(34) + subinstr(f, char(34), char(34) + char(34)) + char(34)
        }
        h = h + (k > 1 ? "," : "") + f
    }
    return(any ? h : "")
}

void _ddp_prepend(string scalar body, string scalar dest, string scalar header)
{
    real scalar fi, fo
    string scalar chunk
    if (fileexists(dest)) unlink(dest)
    fo = fopen(dest, "w")
    fwrite(fo, header + char(10))
    fi = fopen(body, "r")
    while ((chunk = fread(fi, 1048576)) != J(0, 0, "")) fwrite(fo, chunk)
    fclose(fi)
    fclose(fo)
}

void _ddp_utf16_to_utf8(string scalar src, string scalar dest)
{
    string scalar s, enc
    s = _ddp_slurp(src)
    enc = (substr(s, 1, 1) == char(255) ? "utf-16le" : "utf-16be")
    if (mod(strlen(s), 2)) s = substr(s, 1, strlen(s) - 1)
    _ddp_spit(dest, ustrfrom(substr(s, 3, .), enc, 1))
}

string scalar _ddp_binary_vars()
{
    string scalar out
    string colvector x
    real scalar k
    out = ""
    for (k = 1; k <= st_nvar(); k++) {
        if (st_vartype(k) != "strL") continue
        x = st_sdata(., k)
        if (rows(x)) {
            if (any(strpos(x, char(0)))) out = out + (out == "" ? "" : " ") + st_varname(k)
        }
    }
    return(out)
}

string scalar _ddp_find_qchar()
{
    string rowvector cands
    string colvector names
    real scalar i, k, j
    cands = ("question", "question_text", "qtext", "item", "item_text", "wording", "prompt", "Question")
    for (i = 1; i <= cols(cands); i++) {
        for (k = 1; k <= st_nvar(); k++) {
            names = st_dir("char", st_varname(k), "*")
            for (j = 1; j <= rows(names); j++) if (names[j] == cands[i]) return(cands[i])
        }
    }
    return("")
}

void _ddp_rowwidth(string scalar vlist, string scalar sel)
{
    string rowvector v
    string scalar t
    real scalar k, w, avg
    string colvector s
    v = tokens(vlist)
    w = 0
    for (k = 1; k <= cols(v); k++) {
        t = st_vartype(v[k])
        if (t == "byte") w = w + 1
        else if (t == "int") w = w + 2
        else if (t == "long" | t == "float") w = w + 4
        else if (t == "double") w = w + 8
        else if (t == "strL") {
            s = st_sdata(., v[k], sel)
            avg = (rows(s) ? mean(strlen(s)) : 0)
            w = w + 8 + avg
        }
        else w = w + strtoreal(substr(t, 4, .))
    }
    st_local("r_width", strofreal(w, "%21.0f"))
}

// write the four metadata tables for the data in the current frame
void _ddp_extract(string scalar root, string scalar ds, string scalar qchar,
                  string scalar sets, string scalar dlab, string scalar sortedby,
                  string scalar source, real scalar announce)
{
    real scalar K, k, i, j, n, nc
    string scalar nm, typ, fmt, kind, lab, full, ext, orig
    string matrix V, L, C, D
    string colvector names, txt
    string rowvector setv, vlist
    real colvector vals, p
    real matrix x

    K = st_nvar()
    V = J(K + 1, 9, "")
    V[1, .] = ("position", "name", "stata_name", "stata_type", "kind", "format",
               "label", "value_labels", "extended_missing")
    for (k = 1; k <= K; k++) {
        nm = st_varname(k)
        typ = st_vartype(k)
        fmt = st_varformat(k)
        kind = _ddp_kind(typ, fmt)
        lab = st_varlabel(k)
        full = st_global(nm + "[datadeposit_label]")
        if (full != "" & usubstr(full, 1, 80) == lab) lab = full
        ext = "0"
        if (kind != "string" & st_nobs() > 0) {
            st_view(x, ., k)
            if (any(x :> .)) ext = "1"
        }
        orig = st_global(nm + "[datadeposit_name]")
        V[k + 1, .] = (strofreal(k), (orig != "" ? orig : nm), nm, typ, kind, fmt, lab, st_varvaluelabel(k), ext)
    }
    _ddp_writecsv(_ddp_meta(root, ds, "variables"), V)

    // value labels: every defined set, sorted by name then value
    setv = tokens(sets)
    if (cols(setv)) setv = sort(setv', 1)'
    n = 0
    for (i = 1; i <= cols(setv); i++) {
        st_vlload(setv[i], vals, txt)
        n = n + rows(vals)
    }
    L = J(n + 1, 3, "")
    L[1, .] = ("set", "value", "label")
    n = 1
    for (i = 1; i <= cols(setv); i++) {
        st_vlload(setv[i], vals, txt)
        if (!rows(vals)) continue
        p = order(vals, 1)
        for (j = 1; j <= rows(vals); j++) {
            n++
            L[n, .] = (setv[i], _ddp_vfmt(vals[p[j]]), txt[p[j]])
        }
    }
    _ddp_writecsv(_ddp_meta(root, ds, "valuelabels"), L)

    // characteristics: _dta first, then variables in position order
    vlist = ("_dta", st_varname(1..K))
    nc = 0
    for (k = 1; k <= cols(vlist); k++) nc = nc + rows(st_dir("char", vlist[k], "*"))
    C = J(nc + 1, 3, "")
    C[1, .] = ("variable", "char", "text")
    n = 1
    for (k = 1; k <= cols(vlist); k++) {
        names = st_dir("char", vlist[k], "*")
        if (!rows(names)) continue
        names = sort(names, 1)
        for (j = 1; j <= rows(names); j++) {
            if (names[j] == "datadeposit_label" | names[j] == "datadeposit_name") continue
            if (vlist[k] == "_dta" & names[j] == "datadeposit_source") continue
            n++
            C[n, .] = (vlist[k], names[j], st_global(vlist[k] + "[" + names[j] + "]"))
        }
    }
    C = C[|1, 1 \ n, 3|]
    _ddp_writecsv(_ddp_meta(root, ds, "chars"), C)

    D = ("key", "value") \ ("dataset", ds) \ ("label", dlab) \
        ("n_obs", strofreal(st_nobs(), "%21.0f")) \ ("n_vars", strofreal(K)) \
        ("sortedby", sortedby) \ ("question_char", qchar) \
        ("source_file", source) \ ("spec_version", "1.0")
    _ddp_writecsv(_ddp_meta(root, ds, "dataset"), D)
}

// per-variable statistics and frequencies of labelled variables
void _ddp_stats(string scalar root, string scalar ds)
{
    real scalar K, k, N, sys, ext, valid, i, j, cnt, nsys, nF
    string scalar kind, fmt, set, mn, mx, me, sd
    string matrix S, F
    string colvector s, txt
    real colvector x, xv, vals, xs, uniq, counts, allv
    real matrix info

    K = st_nvar()
    N = st_nobs()
    S = J(K + 1, 9, "")
    S[1, .] = ("variable", "kind", "n_valid", "n_missing", "n_extended", "min", "max", "mean", "sd")
    F = J(1024, 4, "")
    F[1, .] = ("variable", "value", "label", "count")
    nF = 1
    for (k = 1; k <= K; k++) {
        kind = _ddp_kind(st_vartype(k), st_varformat(k))
        fmt = subinstr(st_varformat(k), "%-", "%", 1)
        if (kind == "string") {
            s = st_sdata(., k)
            valid = (N ? sum(s :!= "") : 0)
            S[k + 1, .] = (st_varname(k), kind, strofreal(valid, "%21.0f"),
                           strofreal(N - valid, "%21.0f"), "0", "", "", "", "")
            continue
        }
        x = st_data(., k)
        sys = (N ? sum(x :== .) : 0)
        ext = (N ? sum(x :> .) : 0)
        valid = N - sys - ext
        mn = mx = me = sd = ""
        if (valid) {
            xv = select(x, x :< .)
            if (kind == "date") {
                mn = strtrim(strofreal(min(xv), "%tdCCYY-NN-DD"))
                mx = strtrim(strofreal(max(xv), "%tdCCYY-NN-DD"))
            }
            else if (kind == "datetime") {
                mn = strtrim(strofreal(min(xv), (substr(fmt, 1, 3) == "%tC" ? "%tCCCYY-NN-DD_HH:MM:SS.sss" : "%tcCCYY-NN-DD_HH:MM:SS.sss")))
                mx = strtrim(strofreal(max(xv), (substr(fmt, 1, 3) == "%tC" ? "%tCCCYY-NN-DD_HH:MM:SS.sss" : "%tcCCYY-NN-DD_HH:MM:SS.sss")))
            }
            else {
                mn = _ddp_fmtnum(min(xv))
                mx = _ddp_fmtnum(max(xv))
                me = _ddp_fmtnum(mean(xv))
                if (valid > 1) sd = _ddp_fmtnum(sqrt(variance(xv)))
            }
        }
        S[k + 1, .] = (st_varname(k), kind, strofreal(valid, "%21.0f"), strofreal(sys, "%21.0f"),
                       strofreal(ext, "%21.0f"), mn, mx, me, sd)

        set = st_varvaluelabel(k)
        if (set == "" | kind != "numeric") continue
        st_vlload(set, vals, txt)
        nsys = sys
        xs = select(x, x :!= .)
        if (rows(xs)) {
            xs = sort(xs, 1)
            info = panelsetup(xs, 1)
            uniq = xs[info[., 1]]
            counts = info[., 2] - info[., 1] :+ 1
        }
        else {
            uniq = J(0, 1, .)
            counts = J(0, 1, .)
        }
        allv = uniqrows(vals \ uniq)
        for (i = 1; i <= rows(allv); i++) {
            cnt = 0
            for (j = 1; j <= rows(uniq); j++) if (uniq[j] == allv[i]) cnt = counts[j]
            set = ""
            for (j = 1; j <= rows(vals); j++) if (vals[j] == allv[i]) set = txt[j]
            nF++
            if (nF > rows(F)) F = F \ J(rows(F), 4, "")
            F[nF, .] = (st_varname(k), _ddp_vfmt(allv[i]), set, strofreal(cnt, "%21.0f"))
        }
        if (nsys) {
            nF++
            if (nF > rows(F)) F = F \ J(rows(F), 4, "")
            F[nF, .] = (st_varname(k), ".", "", strofreal(nsys, "%21.0f"))
        }
    }
    _ddp_writecsv(_ddp_meta(root, ds, "summary"), S)
    _ddp_writecsv(_ddp_meta(root, ds, "frequencies"), F[|1, 1 \ nF, 4|])
}

void _ddp_write_template(string scalar root, string scalar ds, string scalar lang)
{
    string scalar t
    t = subinstr(_ddp_template(lang), "__DATASET__", ds)
    _ddp_spit(root + "/setup/" + ds + "_setup." + lang, t)
}

// ---- text helpers -----------------------------------------------------------
string scalar _ddp_mdcell(string scalar s0)
{
    string scalar s
    s = subinstr(s0, char(13) + char(10), char(10))
    s = subinstr(s, "|", char(92) + "|")
    return(subinstr(s, char(10), "<br>"))
}

string scalar _ddp_mdquote(string scalar s0)
{
    string scalar s
    s = subinstr(s0, char(13) + char(10), char(10))
    return("> " + subinstr(s, char(10), char(10) + "> "))
}

string scalar _ddp_xml(string scalar s0)
{
    real scalar c
    string scalar s
    s = subinstr(s0, "&", "&amp;")
    s = subinstr(s, "<", "&lt;")
    s = subinstr(s, ">", "&gt;")
    s = subinstr(s, char(34), "&quot;")
    for (c = 0; c < 32; c++) {
        if (c != 9 & c != 10 & c != 13) s = subinstr(s, char(c), "")
    }
    return(s)
}

string scalar _ddp_js(string scalar s0)
{
    real scalar c
    string scalar hex, s
    s = subinstr(s0, char(92), char(92) + char(92))
    s = subinstr(s, char(34), char(92) + char(34))
    s = subinstr(s, char(10), char(92) + "n")
    s = subinstr(s, char(13), char(92) + "r")
    s = subinstr(s, char(9), char(92) + "t")
    s = subinstr(s, char(8), char(92) + "b")
    s = subinstr(s, char(12), char(92) + "f")
    for (c = 0; c < 32; c++) {
        if (strpos(s, char(c))) {
            hex = substr("0123456789abcdef", floor(c / 16) + 1, 1) + substr("0123456789abcdef", mod(c, 16) + 1, 1)
            s = subinstr(s, char(c), char(92) + "u00" + hex)
        }
    }
    return(char(34) + s + char(34))
}

// first and last row of each name's block in a table column (0, -1 when absent);
// loops still test equality, so a block that is not contiguous stays correct
real matrix _ddp_blocks(string colvector col, string colvector names)
{
    real matrix r
    real rowvector fl
    real scalar i, k
    transmorphic A
    A = asarray_create()
    for (i = 1; i <= rows(col); i++) {
        if (asarray_contains(A, col[i])) {
            fl = asarray(A, col[i])
            fl[2] = i
            asarray(A, col[i], fl)
        }
        else asarray(A, col[i], (i, i))
    }
    r = J(rows(names), 2, 0)
    for (k = 1; k <= rows(names); k++) {
        if (asarray_contains(A, names[k])) r[k, .] = asarray(A, names[k])
        else r[k, .] = (1, 0)
    }
    return(r)
}

real scalar _ddp_wopen(string scalar path)
{
    if (fileexists(path)) unlink(path)
    return(fopen(path, "w"))
}

// write what has accumulated and empty the buffer (keeps long files linear in time)
void _ddp_flush(real scalar fh, string scalar out)
{
    if (strlen(out)) fwrite(fh, out)
    out = ""
}

// ---- codebook markdown -----------------------------------------------------
void _ddp_codebook_md(string scalar root, string scalar ds)
{
    string matrix V, L, C, D, S, F
    string scalar out, nl, q, dlab, qchar, set, t, cn
    string colvector vname, vlab, vtype, vkind, vfmt, vvl, lset, lval, llab, cvar, cname, ctext
    string colvector sname, sval, smis, sext, smin, smax, smean, ssd, fvar, fval, flab, fcnt, dk, dv
    real scalar k, i, K, hasS, hasF, fh
    real matrix cb, sb, fb, lb

    nl = char(10)
    V = _ddp_readcsv(_ddp_meta(root, ds, "variables"))
    L = _ddp_readcsv(_ddp_meta(root, ds, "valuelabels"))
    C = _ddp_readcsv(_ddp_meta(root, ds, "chars"))
    D = _ddp_readcsv(_ddp_meta(root, ds, "dataset"))
    hasS = fileexists(_ddp_meta(root, ds, "summary"))
    hasF = fileexists(_ddp_meta(root, ds, "frequencies"))
    if (hasS) S = _ddp_readcsv(_ddp_meta(root, ds, "summary"))
    if (hasF) F = _ddp_readcsv(_ddp_meta(root, ds, "frequencies"))
    if (hasS) {
        sname = _ddp_col(S, "variable"); sval = _ddp_col(S, "n_valid"); smis = _ddp_col(S, "n_missing")
        sext = _ddp_col(S, "n_extended"); smin = _ddp_col(S, "min"); smax = _ddp_col(S, "max")
        smean = _ddp_col(S, "mean"); ssd = _ddp_col(S, "sd")
    }
    if (hasF) {
        fvar = _ddp_col(F, "variable"); fval = _ddp_col(F, "value")
        flab = _ddp_col(F, "label"); fcnt = _ddp_col(F, "count")
    }
    vname = _ddp_col(V, "stata_name"); vlab = _ddp_col(V, "label"); vtype = _ddp_col(V, "stata_type")
    vkind = _ddp_col(V, "kind"); vfmt = _ddp_col(V, "format"); vvl = _ddp_col(V, "value_labels")
    lset = _ddp_col(L, "set"); lval = _ddp_col(L, "value"); llab = _ddp_col(L, "label")
    cvar = _ddp_col(C, "variable"); cname = _ddp_col(C, "char"); ctext = _ddp_col(C, "text")
    dk = _ddp_col(D, "key"); dv = _ddp_col(D, "value")
    dlab = ""; qchar = ""
    for (i = 1; i <= rows(dk); i++) {
        if (dk[i] == "label") dlab = dv[i]
        if (dk[i] == "question_char") qchar = dv[i]
    }
    K = rows(vname)
    cb = _ddp_blocks(cvar, vname)
    lb = _ddp_blocks(lset, vvl)
    if (hasS) sb = _ddp_blocks(sname, vname)
    if (hasF) fb = _ddp_blocks(fvar, vname)
    fh = _ddp_wopen(root + "/codebook/" + ds + "_codebook.md")

    out = "# Codebook: " + ds + nl + nl
    if (dlab != "") out = out + dlab + nl + nl
    out = out + "| Item | Value |" + nl + "|---|---|" + nl
    for (i = 1; i <= rows(dk); i++) {
        if (dk[i] == "dataset" | dk[i] == "label" | dk[i] == "spec_version") continue
        out = out + "| " + dk[i] + " | " + _ddp_mdcell(dv[i]) + " |" + nl
    }
    out = out + nl
    t = _ddp_md_chars("_dta", cvar, cname, ctext, "", 1, rows(cvar))
    if (t != "") out = out + "## Dataset notes and characteristics" + nl + nl + t
    out = out + "## Variables" + nl + nl
    out = out + "| # | Name | Label | Type | Value labels |" + nl + "|---|---|---|---|---|" + nl
    for (k = 1; k <= K; k++) {
        out = out + "| " + strofreal(k) + " | " + vname[k] + " | " + _ddp_mdcell(vlab[k]) + " | " +
              vtype[k] + " | " + vvl[k] + " |" + nl
        _ddp_flush(fh, out)
    }
    out = out + nl
    for (k = 1; k <= K; k++) {
        out = out + "### " + vname[k] + nl + nl
        if (vlab[k] != "") out = out + "**Label:** " + _ddp_mdcell(vlab[k]) + nl + nl
        if (qchar != "") {
            for (i = cb[k, 1]; i <= cb[k, 2]; i++) {
                if (cvar[i] == vname[k] & cname[i] == qchar) {
                    out = out + "**Question text:**" + nl + nl + _ddp_mdquote(ctext[i]) + nl + nl
                }
            }
        }
        out = out + "**Type:** " + vtype[k] + " (" + vkind[k] + "), format " + vfmt[k] + nl + nl
        if (hasS) {
            for (i = sb[k, 1]; i <= sb[k, 2]; i++) {
                if (sname[i] != vname[k]) continue
                t = "**Values:** " + sval[i] + " valid, " + smis[i] + (vkind[k] == "string" ? " empty" : " missing")
                if (sext[i] != "0") t = t + ", " + sext[i] + " extended missing"
                if (smin[i] != "") t = t + "; min " + smin[i] + ", max " + smax[i]
                if (smean[i] != "") t = t + ", mean " + smean[i]
                if (ssd[i] != "") t = t + ", sd " + ssd[i]
                out = out + t + nl + nl
            }
        }
        set = vvl[k]
        if (set != "") {
            out = out + "**Value labels** (" + set + "):" + nl + nl
            if (hasF) {
                out = out + "| Value | Label | Count |" + nl + "|---|---|---|" + nl
                for (i = fb[k, 1]; i <= fb[k, 2]; i++) {
                    if (fvar[i] == vname[k]) {
                        out = out + "| " + fval[i] + " | " + _ddp_mdcell(flab[i]) + " | " + fcnt[i] + " |" + nl
                    }
                }
            }
            else {
                out = out + "| Value | Label |" + nl + "|---|---|" + nl
                for (i = lb[k, 1]; i <= lb[k, 2]; i++) {
                    if (lset[i] == set) out = out + "| " + lval[i] + " | " + _ddp_mdcell(llab[i]) + " |" + nl
                }
            }
            out = out + nl
        }
        out = out + _ddp_md_chars(vname[k], cvar, cname, ctext, qchar, cb[k, 1], cb[k, 2])
        _ddp_flush(fh, out)
    }
    _ddp_flush(fh, out)
    fclose(fh)
}

string scalar _ddp_md_chars(string scalar v, string colvector cvar, string colvector cname,
                            string colvector ctext, string scalar qchar,
                            real scalar lo, real scalar hi)
{
    string scalar out, notes, other, nl
    real scalar i, nn, j
    real colvector nums
    string colvector ntext
    nl = char(10)
    // notes in numeric order
    nn = 0
    for (i = lo; i <= hi; i++) {
        if (cvar[i] == v & regexm(cname[i], "^note[0-9]+" + char(36)) & cname[i] != "note0") nn++
    }
    notes = ""
    if (nn) {
        nums = J(nn, 1, .)
        ntext = J(nn, 1, "")
        j = 0
        for (i = lo; i <= hi; i++) {
            if (cvar[i] == v & regexm(cname[i], "^note[0-9]+" + char(36)) & cname[i] != "note0") {
                j++
                nums[j] = strtoreal(substr(cname[i], 5, .))
                ntext[j] = ctext[i]
            }
        }
        ntext = ntext[order(nums, 1)]
        notes = "**Notes:**" + nl + nl
        for (j = 1; j <= nn; j++) notes = notes + strofreal(j) + ". " + _ddp_mdcell(ntext[j]) + nl
        notes = notes + nl
    }
    other = ""
    for (i = lo; i <= hi; i++) {
        if (cvar[i] != v | regexm(cname[i], "^note[0-9]+" + char(36)) | cname[i] == qchar) continue
        if (other == "") other = "**Characteristics:**" + nl + nl
        other = other + "- " + cname[i] + ": " + _ddp_mdcell(ctext[i]) + nl
    }
    if (other != "") other = other + nl
    return(notes + other)
}

// ---- DDI Codebook 2.5 --------------------------------------------------------
void _ddp_ddi(string scalar root, string scalar ds)
{
    string matrix V, L, C, D, S, F
    string scalar out, nl, qchar, dlab, nobs, nvar, t, set
    string colvector vname, vlab, vkind, vfmt, vvl, cvar, cname, ctext, dk, dv
    string colvector sname, sval, smis, sext, smin, smax, smean, ssd, fvar, fval, flab, fcnt, lset, lval, llab
    real scalar k, i, K, hasS, hasF, fh
    real matrix cb, sb, fb, lb
    nl = char(10)
    V = _ddp_readcsv(_ddp_meta(root, ds, "variables"))
    L = _ddp_readcsv(_ddp_meta(root, ds, "valuelabels"))
    C = _ddp_readcsv(_ddp_meta(root, ds, "chars"))
    D = _ddp_readcsv(_ddp_meta(root, ds, "dataset"))
    hasS = fileexists(_ddp_meta(root, ds, "summary"))
    hasF = fileexists(_ddp_meta(root, ds, "frequencies"))
    if (hasS) S = _ddp_readcsv(_ddp_meta(root, ds, "summary"))
    if (hasF) F = _ddp_readcsv(_ddp_meta(root, ds, "frequencies"))
    if (hasS) {
        sname = _ddp_col(S, "variable"); sval = _ddp_col(S, "n_valid"); smis = _ddp_col(S, "n_missing")
        sext = _ddp_col(S, "n_extended"); smin = _ddp_col(S, "min"); smax = _ddp_col(S, "max")
        smean = _ddp_col(S, "mean"); ssd = _ddp_col(S, "sd")
    }
    vname = _ddp_col(V, "stata_name"); vlab = _ddp_col(V, "label"); vkind = _ddp_col(V, "kind")
    vfmt = _ddp_col(V, "format"); vvl = _ddp_col(V, "value_labels")
    lset = _ddp_col(L, "set"); lval = _ddp_col(L, "value"); llab = _ddp_col(L, "label")
    cvar = _ddp_col(C, "variable"); cname = _ddp_col(C, "char"); ctext = _ddp_col(C, "text")
    dk = _ddp_col(D, "key"); dv = _ddp_col(D, "value")
    qchar = dlab = nobs = nvar = ""
    for (i = 1; i <= rows(dk); i++) {
        if (dk[i] == "label") dlab = dv[i]
        if (dk[i] == "question_char") qchar = dv[i]
        if (dk[i] == "n_obs") nobs = dv[i]
        if (dk[i] == "n_vars") nvar = dv[i]
    }
    K = rows(vname)
    cb = _ddp_blocks(cvar, vname)
    lb = _ddp_blocks(lset, vvl)
    if (hasS) sb = _ddp_blocks(sname, vname)
    if (hasF) fb = _ddp_blocks(_ddp_col(F, "variable"), vname)
    fh = _ddp_wopen(root + "/codebook/" + ds + "_ddi.xml")
    out = "<?xml version=" + char(34) + "1.0" + char(34) + " encoding=" + char(34) + "UTF-8" + char(34) + "?>" + nl
    out = out + "<codeBook xmlns=" + char(34) + "ddi:codebook:2_5" + char(34) + " version=" + char(34) + "2.5" + char(34) + ">" + nl
    out = out + "  <stdyDscr>" + nl + "    <citation>" + nl + "      <titlStmt>" + nl
    out = out + "        <titl>" + _ddp_xml(dlab != "" ? dlab : ds) + "</titl>" + nl
    out = out + "      </titlStmt>" + nl + "    </citation>" + nl + "  </stdyDscr>" + nl
    out = out + "  <fileDscr ID=" + char(34) + "F1" + char(34) + ">" + nl + "    <fileTxt>" + nl
    out = out + "      <fileName>" + _ddp_xml(ds) + ".csv</fileName>" + nl
    out = out + "      <dimensns>" + nl + "        <caseQnty>" + nobs + "</caseQnty>" + nl
    out = out + "        <varQnty>" + nvar + "</varQnty>" + nl + "      </dimensns>" + nl
    out = out + "      <fileType>text/csv</fileType>" + nl + "    </fileTxt>" + nl + "  </fileDscr>" + nl
    out = out + "  <dataDscr>" + nl
    for (k = 1; k <= K; k++) {
        t = "    <var ID=" + char(34) + "V" + strofreal(k) + char(34) + " name=" + char(34) + _ddp_xml(vname[k]) +
            char(34) + " files=" + char(34) + "F1" + char(34)
        if (vkind[k] == "numeric") t = t + " intrvl=" + char(34) + (vvl[k] != "" ? "discrete" : "contin") + char(34)
        out = out + t + ">" + nl
        if (vlab[k] != "") out = out + "      <labl>" + _ddp_xml(vlab[k]) + "</labl>" + nl
        if (qchar != "") {
            for (i = cb[k, 1]; i <= cb[k, 2]; i++) {
                if (cvar[i] == vname[k] & cname[i] == qchar) {
                    out = out + "      <qstn>" + nl + "        <qstnLit>" + _ddp_xml(ctext[i]) + "</qstnLit>" + nl + "      </qstn>" + nl
                }
            }
        }
        if (hasS) {
            for (i = sb[k, 1]; i <= sb[k, 2]; i++) {
                if (sname[i] != vname[k]) continue
                out = out + _ddp_ddistat("vald", sval[i])
                out = out + _ddp_ddistat("invd", strofreal(strtoreal(smis[i]) + strtoreal(sext[i]), "%21.0f"))
                if (vkind[k] == "numeric") {
                    out = out + _ddp_ddistat("min", smin[i])
                    out = out + _ddp_ddistat("max", smax[i])
                    out = out + _ddp_ddistat("mean", smean[i])
                    out = out + _ddp_ddistat("stdev", ssd[i])
                }
            }
        }
        set = vvl[k]
        if (set != "") {
            if (hasF) {
                fvar = _ddp_col(F, "variable"); fval = _ddp_col(F, "value")
                flab = _ddp_col(F, "label"); fcnt = _ddp_col(F, "count")
                for (i = fb[k, 1]; i <= fb[k, 2]; i++) {
                    if (fvar[i] != vname[k]) continue
                    out = out + "      <catgry" + (substr(fval[i], 1, 1) == "." ? " missing=" + char(34) + "Y" + char(34) : "") + ">" + nl
                    out = out + "        <catValu>" + _ddp_xml(fval[i]) + "</catValu>" + nl
                    if (flab[i] != "") out = out + "        <labl>" + _ddp_xml(flab[i]) + "</labl>" + nl
                    out = out + "        <catStat type=" + char(34) + "freq" + char(34) + ">" + fcnt[i] + "</catStat>" + nl
                    out = out + "      </catgry>" + nl
                }
            }
            else {
                for (i = lb[k, 1]; i <= lb[k, 2]; i++) {
                    if (lset[i] != set) continue
                    out = out + "      <catgry" + (substr(lval[i], 1, 1) == "." ? " missing=" + char(34) + "Y" + char(34) : "") + ">" + nl
                    out = out + "        <catValu>" + _ddp_xml(lval[i]) + "</catValu>" + nl
                    out = out + "        <labl>" + _ddp_xml(llab[i]) + "</labl>" + nl
                    out = out + "      </catgry>" + nl
                }
            }
        }
        out = out + "      <varFormat type=" + char(34) + (vkind[k] == "string" ? "character" : "numeric") + char(34) +
              " schema=" + char(34) + "other" + char(34) + " formatname=" + char(34) + _ddp_xml(vfmt[k]) + char(34) + "/>" + nl
        for (i = cb[k, 1]; i <= cb[k, 2]; i++) {
            if (cvar[i] == vname[k] & regexm(cname[i], "^note[0-9]+" + char(36)) & cname[i] != "note0") {
                out = out + "      <notes>" + _ddp_xml(ctext[i]) + "</notes>" + nl
            }
        }
        out = out + "    </var>" + nl
        _ddp_flush(fh, out)
    }
    out = out + "  </dataDscr>" + nl + "</codeBook>" + nl
    _ddp_flush(fh, out)
    fclose(fh)
}

string scalar _ddp_ddistat(string scalar type, string scalar v)
{
    if (v == "") return("")
    return("      <sumStat type=" + char(34) + type + char(34) + ">" + v + "</sumStat>" + char(10))
}

// ---- Frictionless datapackage.json -------------------------------------------
void _ddp_datapackage()
{
    string scalar root, out, nl, ds, ftype, t, dlab, qchar, tit, desc
    string rowvector stems, auth
    string matrix V, L, C, D
    string colvector vname, vsname, vlab, vkind, vtype, vfmt, vvl, lset, lval, llab, cvar, cname, ctext, dk, dv
    real scalar d, k, i, first, fh
    real matrix cb, lb
    nl = char(10)
    root = st_local("to")
    stems = tokens(st_local("stems"))
    tit = st_local("title")
    desc = st_local("description")
    fh = _ddp_wopen(root + "/datapackage.json")
    out = "{" + nl
    out = out + "  " + _ddp_js("name") + ": " + _ddp_js(strlower(_ddp_cleanname(_ddp_basename(root)))) + "," + nl
    if (tit != "") out = out + "  " + _ddp_js("title") + ": " + _ddp_js(tit) + "," + nl
    if (desc != "") out = out + "  " + _ddp_js("description") + ": " + _ddp_js(desc) + "," + nl
    out = out + "  " + _ddp_js("version") + ": " + _ddp_js(st_local("version")) + "," + nl
    out = out + "  " + _ddp_js("created") + ": " + _ddp_js(_ddp_now()) + "," + nl
    if (st_local("authors") != "") {
        out = out + "  " + _ddp_js("contributors") + ": [" + nl
        auth = _ddp_split(st_local("authors"), ";")
        for (i = 1; i <= cols(auth); i++) {
            out = out + "    {" + _ddp_js("title") + ": " + _ddp_js(strtrim(auth[i])) + ", " +
                  _ddp_js("roles") + ": [" + _ddp_js("author") + "]}" + (i < cols(auth) ? "," : "") + nl
        }
        out = out + "  ]," + nl
    }
    if (st_local("license") != "") {
        out = out + "  " + _ddp_js("licenses") + ": [{" + _ddp_js("name") + ": " + _ddp_js(st_local("license")) + "}]," + nl
    }
    out = out + "  " + _ddp_js("resources") + ": [" + nl
    for (d = 1; d <= cols(stems); d++) {
        ds = stems[d]
        V = _ddp_readcsv(_ddp_meta(root, ds, "variables"))
        L = _ddp_readcsv(_ddp_meta(root, ds, "valuelabels"))
        C = _ddp_readcsv(_ddp_meta(root, ds, "chars"))
        D = _ddp_readcsv(_ddp_meta(root, ds, "dataset"))
        vname = _ddp_col(V, "name"); vsname = _ddp_col(V, "stata_name"); vlab = _ddp_col(V, "label"); vkind = _ddp_col(V, "kind")
        vtype = _ddp_col(V, "stata_type"); vfmt = _ddp_col(V, "format"); vvl = _ddp_col(V, "value_labels")
        lset = _ddp_col(L, "set"); lval = _ddp_col(L, "value"); llab = _ddp_col(L, "label")
        cvar = _ddp_col(C, "variable"); cname = _ddp_col(C, "char"); ctext = _ddp_col(C, "text")
        dk = _ddp_col(D, "key"); dv = _ddp_col(D, "value")
        dlab = qchar = ""
        for (i = 1; i <= rows(dk); i++) {
            if (dk[i] == "label") dlab = dv[i]
            if (dk[i] == "question_char") qchar = dv[i]
        }
        out = out + "    {" + nl
        out = out + "      " + _ddp_js("name") + ": " + _ddp_js(strlower(ds)) + "," + nl
        out = out + "      " + _ddp_js("path") + ": " + _ddp_js("data/" + ds + ".csv") + "," + nl
        if (dlab != "") out = out + "      " + _ddp_js("title") + ": " + _ddp_js(dlab) + "," + nl
        out = out + "      " + _ddp_js("format") + ": " + _ddp_js("csv") + "," + nl
        out = out + "      " + _ddp_js("mediatype") + ": " + _ddp_js("text/csv") + "," + nl
        out = out + "      " + _ddp_js("encoding") + ": " + _ddp_js("utf-8") + "," + nl
        out = out + "      " + _ddp_js("schema") + ": {" + nl
        out = out + "        " + _ddp_js("fields") + ": [" + nl
        cb = _ddp_blocks(cvar, vsname)
        lb = _ddp_blocks(lset, vvl)
        for (k = 1; k <= rows(vname); k++) {
            if (vkind[k] == "string" | vkind[k] == "date" | vkind[k] == "datetime") ftype = vkind[k]
            else if (vtype[k] == "byte" | vtype[k] == "int" | vtype[k] == "long") ftype = "integer"
            else ftype = "number"
            out = out + "          {" + nl
            out = out + "            " + _ddp_js("name") + ": " + _ddp_js(vname[k]) + "," + nl
            out = out + "            " + _ddp_js("type") + ": " + _ddp_js(ftype) + "," + nl
            if (vlab[k] != "") out = out + "            " + _ddp_js("title") + ": " + _ddp_js(vlab[k]) + "," + nl
            if (qchar != "") {
                for (i = cb[k, 1]; i <= cb[k, 2]; i++) {
                    if (cvar[i] == vsname[k] & cname[i] == qchar) {
                        out = out + "            " + _ddp_js("description") + ": " + _ddp_js(ctext[i]) + "," + nl
                    }
                }
            }
            if (vvl[k] != "") {
                t = ""
                first = 1
                for (i = lb[k, 1]; i <= lb[k, 2]; i++) {
                    if (lset[i] != vvl[k] | substr(lval[i], 1, 1) == ".") continue
                    t = t + (first ? "" : ", ") + "{" + _ddp_js("value") + ": " + lval[i] + ", " + _ddp_js("label") + ": " + _ddp_js(llab[i]) + "}"
                    first = 0
                }
                if (t != "") out = out + "            " + _ddp_js("categories") + ": [" + t + "]," + nl
            }
            t = "{" + _ddp_js("value") + ": " + _ddp_js("") + ", " + _ddp_js("label") + ": " + _ddp_js("missing") + "}"
            if (vvl[k] != "") {
                for (i = lb[k, 1]; i <= lb[k, 2]; i++) {
                    if (lset[i] == vvl[k] & substr(lval[i], 1, 1) == ".") {
                        t = t + ", {" + _ddp_js("value") + ": " + _ddp_js(lval[i]) + ", " + _ddp_js("label") + ": " + _ddp_js(llab[i]) + "}"
                    }
                }
            }
            out = out + "            " + _ddp_js("missingValues") + ": [" + t + "]," + nl
            out = out + "            " + _ddp_js("stata") + ": {" + _ddp_js("name") + ": " + _ddp_js(vsname[k]) + ", " +
                  _ddp_js("type") + ": " + _ddp_js(vtype[k]) + ", " + _ddp_js("format") + ": " + _ddp_js(vfmt[k]) + ", " +
                  _ddp_js("valueLabels") + ": " + _ddp_js(vvl[k]) + "}" + nl
            out = out + "          }" + (k < rows(vname) ? "," : "") + nl
            _ddp_flush(fh, out)
        }
        out = out + "        ]" + nl + "      }" + nl
        out = out + "    }" + (d < cols(stems) ? "," : "") + nl
    }
    out = out + "  ]" + nl + "}" + nl
    _ddp_flush(fh, out)
    fclose(fh)
}

// ---- README.md -----------------------------------------------------------------
void _ddp_readme()
{
    string scalar root, out, nl, ds, tit, dlab, fmts, prof, t, pkg, fe
    string rowvector stems, files, dparts
    string matrix D
    string colvector dk, dv
    real scalar d, i, sz
    nl = char(10)
    fe = char(96) + char(96) + char(96)
    root = st_local("to")
    stems = tokens(st_local("stems"))
    fmts = st_local("fmts")
    prof = st_local("profile")
    pkg = "datadeposit 0.1.0"
    tit = st_local("title")
    if (tit == "") tit = "Data deposit: " + invtokens(stems, ", ")
    out = "# " + tit + nl + nl
    if (st_local("description") != "") out = out + st_local("description") + nl + nl
    out = out + "This folder is an archive-ready data deposit. It holds the data, a codebook, " +
          "and setup scripts that rebuild the labelled data in Stata, R, and Python from " +
          "the plain-text csv. It was written by " + pkg + " in Stata " + st_local("dversion") +
          " on " + _ddp_now() + "." + nl + nl
    out = out + "| Item | Value |" + nl + "|---|---|" + nl
    if (st_local("authors") != "") out = out + "| Authors | " + _ddp_mdcell(st_local("authors")) + " |" + nl
    out = out + "| Version | " + _ddp_mdcell(st_local("version")) + " |" + nl
    out = out + "| Profile | " + prof + " |" + nl
    if (st_local("license") != "") out = out + "| License | " + _ddp_mdcell(st_local("license")) + " |" + nl
    if (st_local("changes") != "") out = out + "| Changes in this version | " + _ddp_mdcell(st_local("changes")) + " |" + nl
    if (st_local("derived") != "") {
        dparts = _ddp_split(st_local("derived"), "|")
        while (cols(dparts) < 3) dparts = dparts, ""
        out = out + "| Derived from | version " + _ddp_mdcell(dparts[2]) + " in " + _ddp_mdcell(dparts[1]) +
              " (MANIFEST.json sha256 " + substr(dparts[3], 1, 12) + ") |" + nl
    }
    out = out + nl + "## Datasets" + nl + nl
    out = out + "| Dataset | Label | Observations | Variables |" + nl + "|---|---|---|---|" + nl
    for (d = 1; d <= cols(stems); d++) {
        ds = stems[d]
        D = _ddp_readcsv(_ddp_meta(root, ds, "dataset"))
        dk = _ddp_col(D, "key"); dv = _ddp_col(D, "value")
        dlab = t = ""
        for (i = 1; i <= rows(dk); i++) {
            if (dk[i] == "label") dlab = dv[i]
            if (dk[i] == "n_obs") t = dv[i]
        }
        for (i = 1; i <= rows(dk); i++) if (dk[i] == "n_vars") t = t + " | " + dv[i]
        out = out + "| " + ds + " | " + _ddp_mdcell(dlab) + " | " + t + " |" + nl
    }
    out = out + nl + "## How to open the data" + nl + nl
    ds = stems[1]
    out = out + "Each dataset has the same files; the examples use " + char(96) + ds + char(96) + "." + nl + nl
    out = out + "**Stata.** Open the native file, or rebuild it from the csv:" + nl + nl
    out = out + fe + "stata" + nl
    if (fileexists(root + "/data/" + ds + ".dta")) out = out + "use " + char(34) + "data/" + ds + ".dta" + char(34) + ", clear" + nl
    out = out + "do " + char(34) + "setup/" + ds + "_setup.do" + char(34) + nl
    out = out + "* or, with the datadeposit package installed:" + nl
    out = out + "datadeposit use " + char(34) + "." + char(34) + ", clear" + nl + fe + nl + nl
    out = out + "**R.** Read the native file, or rebuild it from the csv:" + nl + nl
    out = out + fe + "r" + nl
    if (fileexists(root + "/data/" + ds + ".rds")) out = out + ds + " <- readRDS(" + char(34) + "data/" + ds + ".rds" + char(34) + ")" + nl
    out = out + "source(" + char(34) + "setup/" + ds + "_setup.R" + char(34) + ")   # creates " + ds + nl + fe + nl + nl
    out = out + "**Python.** Rebuild it from the csv with pandas:" + nl + nl
    out = out + fe + "python" + nl + "import runpy" + nl
    out = out + "df = runpy.run_path(" + char(34) + "setup/" + ds + "_setup.py" + char(34) + ")[" + char(34) + "load" + char(34) + "]()" + nl
    out = out + "df.attrs[" + char(34) + "column_names_to_labels" + char(34) + "]   # variable labels" + nl + fe + nl + nl
    out = out + "**Excel.** Open " + char(96) + "data/" + ds + ".csv" + char(96) + " for the values and " +
          char(96) + "codebook/" + ds + "_codebook.xlsx" + char(96) + " for labels, value labels, and question text." + nl + nl
    if (prof == "lean") {
        out = out + "This deposit uses the lean profile: it keeps the native file and one csv, " +
              "and the setup scripts build the R and Python versions on demand." + nl + nl
    }
    if (prof == "nodata") {
        out = out + "This deposit holds no data files (nodata profile). The setup scripts expect " +
              "the csv at " + char(96) + "data/<dataset>.csv" + char(96) + "." + nl + nl
    }
    out = out + "## Files" + nl + nl
    out = out + "| File | Bytes | What it is |" + nl + "|---|---|---|" + nl
    files = tokens(_ddp_listfiles(root))
    for (i = 1; i <= cols(files); i++) {
        if (files[i] == "README.md" | files[i] == "MANIFEST.json") continue
        sz = _ddp_filesize(root + "/" + files[i])
        out = out + "| " + files[i] + " | " + strofreal(sz, "%21.0fc") + " | " + _ddp_what(files[i]) + " |" + nl
    }
    out = out + "| MANIFEST.json | | sizes and sha256 hashes of every file |" + nl
    out = out + nl + "## Checking and changing this deposit" + nl + nl
    out = out + "Run " + char(96) + "datadeposit verify " + char(34) + "<this folder>" + char(34) + char(96) +
          " (Stata), " + char(96) + "deposit_verify()" + char(96) + " (R or Python) to confirm that no file changed " +
          "and that the csv still rebuilds the data exactly." + nl + nl
    out = out + "Do not edit files here. To publish changed data, load it with " + char(96) + "datadeposit use" + char(96) +
          ", make the changes, and write a new deposit with " + char(96) + "version()" + char(96) + " and " +
          char(96) + "changes()" + char(96) + "; the new deposit records this one as its parent." + nl + nl
    out = out + "Folder layout and rules: deposit specification 1.0, https://github.com/ericabooth/datadeposit" + nl
    _ddp_spit(root + "/README.md", out)
}

string scalar _ddp_what(string scalar f)
{
    if (regexm(f, "^data/.*[.]csv" + char(36))) return("the data, plain text (codes, not labels)")
    if (regexm(f, "^data/.*[.]dta" + char(36))) return("the data for Stata")
    if (regexm(f, "^data/.*[.]rds" + char(36))) return("the data for R (base data.frame with attributes)")
    if (regexm(f, "^data/.*[.]xlsx" + char(36))) return("the data for Excel (codes sheet and labels sheet)")
    if (regexm(f, "^data/.*[.]sav" + char(36))) return("the data for SPSS")
    if (regexm(f, "_variables[.]csv" + char(36))) return("one row per variable: type, format, label, value label set")
    if (regexm(f, "_valuelabels[.]csv" + char(36))) return("every value label")
    if (regexm(f, "_chars[.]csv" + char(36))) return("notes and characteristics, including item text")
    if (regexm(f, "_dataset[.]csv" + char(36))) return("dataset label, size, sort order")
    if (regexm(f, "_summary[.]csv" + char(36))) return("statistics for each variable")
    if (regexm(f, "_frequencies[.]csv" + char(36))) return("counts for every labelled variable")
    if (regexm(f, "_codebook[.]md" + char(36))) return("codebook to read")
    if (regexm(f, "_codebook[.]xlsx" + char(36))) return("codebook as Excel sheets")
    if (regexm(f, "_ddi[.]xml" + char(36))) return("DDI Codebook 2.5 for data archives")
    if (regexm(f, "_setup[.]do" + char(36))) return("rebuilds the data in Stata")
    if (regexm(f, "_setup[.]R" + char(36))) return("rebuilds the data in R")
    if (regexm(f, "_setup[.]py" + char(36))) return("rebuilds the data in Python")
    if (f == "datapackage.json") return("Frictionless Data Package description")
    if (substr(f, 1, 5) == "docs/") return("included document")
    return("")
}

// ---- MANIFEST.json -------------------------------------------------------------
void _ddp_write_manifest()
{
    string scalar root, out, nl, f, eng, der
    string rowvector files, parts
    real scalar i
    nl = char(10)
    root = st_local("to")
    files = tokens(st_local("flist"))
    out = "{" + nl
    out = out + "  " + _ddp_js("datadeposit") + ": " + _ddp_js("1.0") + "," + nl
    out = out + "  " + _ddp_js("package") + ": " + _ddp_js("datadeposit 0.1.0") + "," + nl
    out = out + "  " + _ddp_js("software") + ": " + _ddp_js("Stata " + st_local("dversion")) + "," + nl
    out = out + "  " + _ddp_js("created") + ": " + _ddp_js(_ddp_now()) + "," + nl
    out = out + "  " + _ddp_js("title") + ": " + _ddp_js(st_local("title")) + "," + nl
    out = out + "  " + _ddp_js("version") + ": " + _ddp_js(st_local("version")) + "," + nl
    out = out + "  " + _ddp_js("changes") + ": " + _ddp_js(st_local("changes")) + "," + nl
    out = out + "  " + _ddp_js("profile") + ": " + _ddp_js(st_local("profile")) + "," + nl
    der = st_local("derived")
    if (der == "") out = out + "  " + _ddp_js("derived_from") + ": null," + nl
    else {
        parts = _ddp_split(der, "|")
        while (cols(parts) < 3) parts = parts, ""
        out = out + "  " + _ddp_js("derived_from") + ": {" + _ddp_js("path") + ": " + _ddp_js(parts[1]) + ", " +
              _ddp_js("version") + ": " + _ddp_js(parts[2]) + ", " + _ddp_js("manifest_sha256") + ": " + _ddp_js(parts[3]) + "}," + nl
    }
    out = out + "  " + _ddp_js("size_check") + ": {" + _ddp_js("max_gb") + ": " + _ddp_fmtnum(strtoreal(st_local("maxsize"))) + ", " +
          _ddp_js("largest_file_gb") + ": " + _ddp_fmtnum(round(strtoreal(st_local("largest")) / 1e9, .001)) + ", " +
          _ddp_js("override") + ": " + _ddp_js(st_local("size_override")) + "}," + nl
    out = out + "  " + _ddp_js("datasets") + ": [" + invtokens(_ddp_jsv(tokens(st_local("stems"))), ", ") + "]," + nl
    out = out + "  " + _ddp_js("files") + ": [" + nl
    for (i = 1; i <= cols(files); i++) {
        f = files[i]
        eng = "stata"
        if (regexm(f, "^data/.*[.](rds|sav)" + char(36))) eng = "R via setup.R"
        out = out + "    {" + _ddp_js("path") + ": " + _ddp_js(f) + ", " + _ddp_js("bytes") + ": " +
              strofreal(_ddp_filesize(root + "/" + f), "%21.0f") + ", " + _ddp_js("sha256") + ": " +
              _ddp_js(st_local("h_" + strofreal(i))) + ", " + _ddp_js("engine") + ": " + _ddp_js(eng) + "}" +
              (i < cols(files) ? "," : "") + nl
    }
    out = out + "  ]" + nl + "}" + nl
    _ddp_spit(root + "/MANIFEST.json", out)
}

string rowvector _ddp_jsv(string rowvector s)
{
    real scalar i
    string rowvector o
    o = s
    for (i = 1; i <= cols(s); i++) o[i] = _ddp_js(s[i])
    return(o)
}

real scalar _ddp_is_deposit(string scalar path)
{
    return(strpos(_ddp_slurp(path), char(34) + "datadeposit" + char(34) + ":") > 0)
}

// read path/bytes/sha256 of each manifest entry into locals m_*
void _ddp_read_manifest(string scalar path)
{
    string rowvector lines
    string scalar l
    real scalar i, n
    lines = _ddp_split(_ddp_slurp(path), char(10))
    n = 0
    for (i = 1; i <= cols(lines); i++) {
        l = lines[i]
        if (!regexm(l, "^ *[{]" + char(34) + "path" + char(34) + ": " + char(34) + "([^" + char(34) + "]*)" + char(34))) continue
        n++
        st_local("m_path_" + strofreal(n), regexs(1))
        if (regexm(l, char(34) + "bytes" + char(34) + ": ([0-9]+)")) st_local("m_bytes_" + strofreal(n), regexs(1))
        if (regexm(l, char(34) + "sha256" + char(34) + ": " + char(34) + "([0-9a-f]*)" + char(34))) st_local("m_sha_" + strofreal(n), regexs(1))
    }
    st_local("m_n", strofreal(n))
}

string scalar _ddp_manifest_key(string scalar path, string scalar key)
{
    string scalar s
    s = _ddp_slurp(path)
    if (regexm(s, char(34) + key + char(34) + ": " + char(34) + "([^" + char(34) + "]*)" + char(34))) return(regexs(1))
    return("")
}

// delete exactly the files an earlier manifest lists, then empty folders
void _ddp_clear_deposit(string scalar root)
{
    real scalar i, n, j
    string scalar sub
    string colvector f
    if (strpos(_ddp_slurp(root + "/MANIFEST.json"), "incomplete")) {
        // an unfinished deposit lists no files: remove what datadeposit writes
        printf("{txt}datadeposit: an earlier deposit in this folder did not finish; replacing it\n")
        for (i = 1; i <= 5; i++) {
            sub = root + "/" + ("data", "metadata", "codebook", "setup", "docs")[i]
            if (direxists(sub)) {
                f = dir(sub, "files", "*")
                for (j = 1; j <= rows(f); j++) unlink(sub + "/" + f[j])
            }
        }
        for (i = 1; i <= 2; i++) {
            sub = root + "/" + ("README.md", "datapackage.json")[i]
            if (fileexists(sub)) unlink(sub)
        }
        st_local("m_n", "0")
    }
    else _ddp_read_manifest(root + "/MANIFEST.json")
    n = strtoreal(st_local("m_n"))
    for (i = 1; i <= n; i++) {
        sub = root + "/" + st_local("m_path_" + strofreal(i))
        if (fileexists(sub)) unlink(sub)
    }
    unlink(root + "/MANIFEST.json")
    for (i = 1; i <= 5; i++) {
        sub = root + "/" + ("data", "metadata", "codebook", "setup", "docs")[i]
        if (direxists(sub)) {
            if (!rows(dir(sub, "files", "*")) & !rows(dir(sub, "dirs", "*"))) (void) _rmdir(sub)
        }
    }
}

// every file under root, relative, sorted in byte order (MANIFEST.json excluded)
string scalar _ddp_listfiles(string scalar root)
{
    string colvector out, f
    string rowvector subs
    real scalar i
    out = dir(root, "files", "*")
    subs = ("codebook", "data", "docs", "metadata", "setup")
    for (i = 1; i <= cols(subs); i++) {
        if (!direxists(root + "/" + subs[i])) continue
        f = dir(root + "/" + subs[i], "files", "*")
        if (rows(f)) out = out \ (subs[i] + "/") :+ f
    }
    out = select(out, out :!= "MANIFEST.json")
    out = select(out, substr(out, 1, 1) :!= ".")
    out = select(out, !strpos(out, "/.") )
    if (!rows(out)) return("")
    out = sort(out, 1)
    return(invtokens(out'))
}

string scalar _ddp_parse_hash(string scalar path)
{
    string rowvector lines
    string scalar l
    real scalar i
    if (!fileexists(path)) return("")
    lines = _ddp_split(_ddp_slurp(path), char(10))
    for (i = 1; i <= cols(lines); i++) {
        l = strlower(subinstr(subinstr(strtrim(lines[i]), " ", ""), char(13), ""))
        if (regexm(l, "^([0-9a-f]{64})")) return(regexs(1))
    }
    return("")
}

// ---- paths and small utilities ---------------------------------------------------
string rowvector _ddp_split(string scalar s0, string scalar sep)
{
    string rowvector out
    string scalar s
    real scalar p
    s = s0
    out = J(1, 0, "")
    while ((p = strpos(s, sep)) > 0) {
        out = out, substr(s, 1, p - 1)
        s = substr(s, p + strlen(sep), .)
    }
    return(out, s)
}

string scalar _ddp_basename(string scalar p0)
{
    string scalar d, f, p
    p = subinstr(p0, char(92), "/")
    while (strlen(p) > 1 & substr(p, strlen(p), 1) == "/") p = substr(p, 1, strlen(p) - 1)
    pathsplit(p, d, f)
    return(f)
}

string scalar _ddp_dirname(string scalar p0)
{
    string scalar d, f, p
    p = subinstr(p0, char(92), "/")
    pathsplit(p, d, f)
    return(d)
}

string scalar _ddp_stem(string scalar p)
{
    string scalar f
    f = _ddp_basename(p)
    if (strlower(substr(f, -3, .)) == ".gz") f = substr(f, 1, strlen(f) - 3)
    if (strpos(f, ".")) f = pathrmsuffix(f)
    return(_ddp_cleanname(f))
}

string scalar _ddp_cleanname(string scalar s0)
{
    string scalar s
    s = ustrregexra(strtrim(s0), "[^A-Za-z0-9_-]", "_")
    if (s == "") s = "data"
    return(s)
}

string scalar _ddp_abspath(string scalar p0)
{
    string scalar p
    p = subinstr(p0, char(92), "/")
    if (pathisabs(p)) return(p)
    if (p == "." | p == "") return(pwd())
    if (substr(p, 1, 2) == "./") p = substr(p, 3, .)
    return(pathjoin(pwd(), p))
}

void _ddp_mkdirs(string scalar p0)
{
    string rowvector parts
    string scalar cur, p
    real scalar i
    p = subinstr(p0, char(92), "/")
    if (direxists(p)) return
    parts = _ddp_split(p, "/")
    cur = ""
    for (i = 1; i <= cols(parts); i++) {
        cur = (i == 1 ? parts[1] : cur + "/" + parts[i])
        if (cur == "" | cur == ".") continue
        if (!direxists(cur)) (void) _mkdir(cur)
    }
    if (!direxists(p)) {
        errprintf("datadeposit: cannot create folder %s\n", p)
        errprintf("  check that the path exists and that you may write there, or choose another place with to()\n")
        exit(693)
    }
}

string scalar _ddp_size(real scalar b)
{
    if (b >= 1e9) return(strtrim(strofreal(b / 1e9, "%9.1f")) + " GB")
    if (b >= 1e6) return(strtrim(strofreal(b / 1e6, "%9.1f")) + " MB")
    return(strtrim(strofreal(max((1, round(b / 1e3))), "%9.0f")) + " KB")
}

void _ddp_parse_prov(string scalar prov)
{
    string rowvector p
    p = _ddp_split(prov, "|")
    while (cols(p) < 4) p = p, ""
    st_local("prev_dir", p[1])
    st_local("prev_ver", p[2])
    st_local("prev_ds", p[4])
}

// ---- content sniffing (same rules as sniff.py and sniff.R) ---------------------
real rowvector _ddp_fieldcounts(string scalar body, real scalar d)
{
    real rowvector b, out
    real scalar i, n, inq, f, blank, nrec
    b = ascii(body)
    n = cols(b)
    out = J(1, 0, .)
    inq = 0
    f = 1
    blank = 1
    nrec = 0
    for (i = 1; i <= n; i++) {
        if (b[i] == 34) inq = !inq
        else if (!inq & b[i] == d) f++
        else if (!inq & (b[i] == 10 | b[i] == 13)) {
            if (b[i] == 13 & i < n) {
                if (b[i + 1] == 10) i++
            }
            if (!blank) {
                out = out, f
                nrec++
                if (nrec >= 200) return(out)
            }
            f = 1
            blank = 1
            continue
        }
        if (b[i] != 32 & b[i] != 9 & b[i] != d) blank = 0
    }
    if (!blank) out = out, f
    return(out)
}

void _ddp_sniff(string scalar path)
{
    real scalar fh, size, i, k, bestd, bestn, bad
    string scalar head, ext, ext0, enc, body, why, s, dec
    string rowvector code, lines
    real rowvector c, delims
    st_local("sn_delim", "")
    st_local("sn_enc", "")
    st_local("sn_dec", ".")
    ext0 = pathsuffix(path)
    ext = strlower(subinstr(ext0, ".", "", 1))
    size = _ddp_filesize(path)
    if (size >= . ) { _ddp_sn("missing", "the file does not exist"); return; }
    if (size == 0) { _ddp_sn("empty", "the file is empty"); return; }
    fh = fopen(path, "r")
    head = fread(fh, 65536)
    fclose(fh)
    if (substr(head, 1, 11) == "<stata_dta>") { _ddp_sn("dta", ""); return; }
    if (strlen(head) > 2) {
        if (anyof((104, 105, 108, 110, 111, 113, 114, 115), ascii(substr(head, 1, 1))) &
            anyof((1, 2), ascii(substr(head, 2, 1))) & ascii(substr(head, 3, 1)) == 1) { _ddp_sn("dta_old", ""); return; }
    }
    if (substr(head, 1, 4) == "PK" + char(3) + char(4)) {
        if (strpos(head, "xl/") | ext == "xlsx" | ext == "xlsm") _ddp_sn("xlsx", "")
        else _ddp_sn("zip", "the file is a zip archive; unzip it first")
        return
    }
    if (substr(head, 1, 4) == char(208) + char(207) + char(17) + char(224)) {
        if (anyof(("doc", "ppt", "msg"), ext)) _ddp_sn("document", "the file is an Office document, not a table")
        else _ddp_sn("xls", "")
        return
    }
    if (substr(head, 1, 4) == char(36) + "FL2" | substr(head, 1, 4) == char(36) + "FL3") { _ddp_sn("sav", ""); return; }
    if (substr(head, 1, 4) == "PAR1") { _ddp_sn("parquet", "the file is Parquet, which Stata cannot read; open it in R or Python"); return; }
    if (substr(head, 1, 4) == "%PDF") { _ddp_sn("document", "the file is a PDF; add it with include() to ship it in docs/"); return; }
    if (substr(head, 1, 4) == char(137) + "PNG" | substr(head, 1, 3) == char(255) + char(216) + char(255) | substr(head, 1, 4) == "GIF8") {
        _ddp_sn("document", "the file is an image; add it with include() to ship it in docs/"); return
    }
    if (substr(head, 1, 2) == char(31) + char(139)) {
        if (ext == "rds") _ddp_sn("rds", "the file is an R data file; deposit it from R")
        else _ddp_sn("gzip", "")
        return
    }
    if (substr(head, 1, 5) == "RDX2" + char(10) | substr(head, 1, 5) == "RDX3" + char(10) | substr(head, 1, 2) == "X" + char(10)) {
        _ddp_sn("rds", "the file is an R data file; deposit it from R"); return
    }
    enc = "utf-8"
    if (substr(head, 1, 2) == char(255) + char(254) | substr(head, 1, 2) == char(254) + char(255)) {
        if (mod(strlen(head), 2)) head = substr(head, 1, strlen(head) - 1)
        head = ustrfrom(substr(head, 3, .), (substr(head, 1, 1) == char(255) ? "utf-16le" : "utf-16be"), 1)
        enc = "utf-16"
    }
    else if (strpos(head, char(0))) {
        _ddp_sn("binary", "the file holds binary data, not text, though its name ends in " + (ext0 != "" ? ext0 : "nothing"))
        return
    }
    if (substr(head, 1, 3) == char(239) + char(187) + char(191)) head = substr(head, 4, .)
    if (enc == "utf-8" & ustrinvalidcnt(head) > (strlen(head) == 65536 ? 3 : 0)) enc = "latin1"
    code = ("do", "ado", "r", "rmd", "qmd", "py", "ipynb", "sas", "sps", "m", "jl", "sql", "sh", "md", "tex",
            "log", "smcl", "pdf", "docx", "doc", "html", "png", "jpg", "gif", "svg", "json", "xml", "yaml", "yml")
    if (anyof(code, ext)) {
        _ddp_sn("code", "the file is code or documentation (" + ext0 + "); add it with include() to ship it in docs/")
        return
    }
    body = head
    if (strlen(head) >= 32768) body = substr(head, 1, strrpos(head, char(10)))
    if (strtrim(subinstr(subinstr(body, char(10), ""), char(13), "")) == "") { _ddp_sn("empty", "the file holds only blank lines"); return; }
    delims = (44, 9, 124, 59)
    bestd = 0
    bestn = 0
    for (k = 1; k <= 4; k++) {
        c = _ddp_fieldcounts(body, delims[k])
        if (!cols(c)) continue
        if (c[1] > 1 & all(c :== c[1]) & c[1] > bestn) {
            bestd = delims[k]
            bestn = c[1]
        }
    }
    if (!bestd) {
        bestn = 0
        for (k = 1; k <= 4; k++) {
            c = _ddp_fieldcounts(body, delims[k])
            if (cols(c)) {
                if (c[1] > bestn) {
                    bestn = c[1]
                    bestd = delims[k]
                }
            }
        }
        if (bestn > 1) {
            c = _ddp_fieldcounts(body, bestd)
            bad = 0
            for (i = 1; i <= cols(c); i++) if (c[i] != c[1] & !bad) bad = i
            _ddp_sn("ragged", "record " + strofreal(bad) + " has " + strofreal(c[bad]) + " fields but the header has " +
                    strofreal(c[1]) + " (delimiter " + (bestd == 9 ? "tab" : char(bestd)) + "); fix the file or read it yourself")
            return
        }
        lines = select(tokens(subinstr(body, char(13), ""), char(10)), tokens(subinstr(body, char(13), ""), char(10)) :!= char(10))
        if (anyof(("csv", "tsv", "txt", "psv", "dat"), ext) & cols(lines)) {
            if (regexm(strtrim(lines[1]), "^[A-Za-z_][A-Za-z0-9_]*" + char(36)) & strlen(strtrim(lines[1])) <= 32 & max(strlen(lines)) <= 80) {
                st_local("sn_delim", ",")
                st_local("sn_enc", enc)
                _ddp_sn("delimited", "")
                return
            }
        }
        _ddp_sn("text", "the file is text with no consistent delimiter (comma, tab, pipe, or semicolon), so it does not look like a table")
        return
    }
    dec = "."
    if (bestd == 59) {
        lines = tokens(subinstr(body, char(13), ""), char(10))
        for (i = 2; i <= cols(lines); i++) {
            if (lines[i] != char(10)) {
                if (ustrregexm(lines[i], "(^|;) *-?[0-9]+,[0-9]+ *(;|" + char(36) + ")")) dec = ","
            }
        }
    }
    st_local("sn_delim", (bestd == 9 ? "tab" : char(bestd)))
    st_local("sn_enc", enc)
    st_local("sn_dec", dec)
    _ddp_sn("delimited", "")
}

void _ddp_sn(string scalar kind, string scalar why)
{
    st_local("sn_kind", kind)
    st_local("sn_why", why)
    st_local("sn_isdata", strofreal(anyof(("dta", "dta_old", "delimited", "xlsx", "xls", "sav", "gzip"), kind)))
}

// first row holds the column names: name the variables after it (Python's rule)
void _ddp_header_from_row1()
{
    string rowvector h, sn, h0
    string scalar note, x
    real scalar k, K, j, n
    real colvector keep
    string matrix X
    K = st_nvar()
    h = J(1, K, "")
    if (st_nobs() >= 1) {
        for (k = 1; k <= K; k++) h[k] = st_sdata(1, k)
        st_dropobsin(1)
    }
    if (K) h[1] = subinstr(h[1], ustrunescape("﻿"), "")
    note = ""
    for (k = 1; k <= K; k++) {
        h[k] = strtrim(h[k])
        if (h[k] == "") h[k] = "v" + strofreal(k)
    }
    h0 = h
    for (k = 2; k <= K; k++) {
        n = 1
        for (j = 1; j < k; j++) if (h0[j] == h0[k]) n++
        if (n > 1) {
            x = h[k] + "_" + strofreal(n)
            note = note + (note == "" ? "" : "; ") + "repeats the column name '" + h[k] + "'; the repeat is named '" + x + "'"
            h[k] = x
        }
    }
    sn = _ddp_stata_names(h)
    for (k = 1; k <= K; k++) st_varrename(k, "__ddp_" + strofreal(k))
    for (k = 1; k <= K; k++) {
        st_varrename(k, sn[k])
        st_varlabel(k, "")
        if (sn[k] != h[k]) st_global(sn[k] + "[datadeposit_name]", h[k])
    }
    // drop rows where every field is empty, as R and pandas do
    if (st_nobs() & K) {
        X = st_sdata(., .)
        keep = rowsum(strtrim(X) :!= "") :> 0
        if (!all(keep)) st_keepobsif(keep)
    }
    st_local("hdr_note", note)
}

string rowvector _ddp_stata_names(string rowvector x)
{
    string rowvector out, reserved
    string scalar s, base, suf
    real scalar i, k
    reserved = ("_dta", "_all", "_b", "byte", "_coef", "_cons", "double", "float", "if", "in", "int", "long", "_n",
                "_N", "_pi", "_pred", "_rc", "_skip", "strL", "using", "with")
    out = J(1, cols(x), "")
    for (i = 1; i <= cols(x); i++) {
        s = ustrregexra(x[i], "[^A-Za-z0-9_]", "_")
        if (s == "" | regexm(substr(s, 1, 1), "[0-9]")) s = "_" + s
        if (anyof(reserved, s) | regexm(s, "^str[0-9]+" + char(36))) s = s + "_"
        s = substr(s, 1, 32)
        base = s
        k = 2
        while (anyof(out[|1 \ max((i - 1, 1))|], s) & i > 1) {
            suf = "_" + strofreal(k)
            s = substr(base, 1, 32 - strlen(suf)) + suf
            k++
        }
        out[i] = s
    }
    return(out)
}

// is this text variable all numbers? sets tc_num, tc_lead0, tc_natok, tc_type, tc_fmt
void _ddp_typecheck(string scalar v, string scalar dec)
{
    string colvector s, t, u
    real colvector ne, y, tok
    real scalar allnum, lead0, w, lo, hi, isint
    string rowvector toks
    s = st_sdata(., v)
    t = strtrim(s)
    toks = ("", "NA", "N/A", "NaN", "nan", "null", "NULL", ".")
    tok = J(rows(t), 1, 0)
    for (w = 1; w <= cols(toks); w++) tok = tok :| (t :== toks[w])
    ne = !tok
    st_local("tc_natok", "0")
    if (!rows(t) | !any(ne)) {
        _ddp_tc_string(s)
        return
    }
    u = (dec == "," ? subinstr(t, ",", ".") : t)
    y = strtoreal(u)
    allnum = all(select(y, ne) :< .)
    lead0 = any(select(regexm(t, "^-?0[0-9]"), ne))
    if (allnum & !lead0) {
        y = select(y, ne)
        isint = all(y :== floor(y))
        lo = min(y)
        hi = max(y)
        st_local("tc_num", "1")
        st_local("tc_lead0", "0")
        st_local("tc_natok", strofreal(any(tok :& (t :!= ""))))
        if (isint & lo >= -127 & hi <= 100) { st_local("tc_type", "byte"); st_local("tc_fmt", "%8.0g"); }
        else if (isint & lo >= -32767 & hi <= 32740) { st_local("tc_type", "int"); st_local("tc_fmt", "%8.0g"); }
        else if (isint & lo >= -2147483647 & hi <= 2147483620) { st_local("tc_type", "long"); st_local("tc_fmt", "%12.0g"); }
        else { st_local("tc_type", "double"); st_local("tc_fmt", "%10.0g"); }
        return
    }
    _ddp_tc_string(s)
    st_local("tc_lead0", strofreal(lead0 & allnum))
}

void _ddp_tc_string(string colvector s)
{
    real scalar w
    w = (rows(s) ? max(strlen(s)) : 0)
    if (w < 1) w = 1
    st_local("tc_num", "0")
    st_local("tc_lead0", "0")
    if (w > 2045) {
        st_local("tc_type", "strL")
        st_local("tc_fmt", "%9s")
    }
    else {
        st_local("tc_type", "str" + strofreal(w))
        st_local("tc_fmt", "%" + strofreal(max((9, w))) + "s")
    }
}

// is this folder inside one of Stata's own directories?
real scalar _ddp_in_sysdir(string scalar dir)
{
    string rowvector sys
    string scalar d, x
    real scalar i
    if (dir == "") return(0)
    d = strlower(subinstr(_ddp_abspath(dir), char(92), "/")) + "/"
    sys = (c("sysdir_stata"), c("sysdir_base"), c("sysdir_site"), c("sysdir_plus"), c("sysdir_personal"), c("sysdir_oldplace"))
    for (i = 1; i <= cols(sys); i++) {
        x = strlower(subinstr(sys[i], char(92), "/"))
        if (x == "" | x == "./" | substr(x, 1, 1) == "~") continue
        if (substr(x, strlen(x), 1) != "/") x = x + "/"
        if (strpos(d, x) == 1) return(1)
    }
    return(0)
}

string scalar _ddp_now()
{
    string scalar d, t
    real scalar dt
    d = c("current_date")
    t = c("current_time")
    dt = date(d, "DMY")
    return(strtrim(strofreal(dt, "%tdCCYY-NN-DD")) + "T" + t)
}

end

* ===== BEGIN EMBEDDED TEMPLATES (generated by tools/sync_templates.py; do not edit) =====
version 14
mata:
string scalar _ddp_template(string scalar which)
{
    string scalar h
    h = ""
    if (which == "do") {
        h = h + "2a2120646174616465706f7369742073657475702066696c6520666f7220537461746120286465706f736974207370656320312e30290a2a212052656275696c64732064617461736574205f5f444154415345545f5f2066726f6d20646174612f5f5f444154415345545f5f2e63737620616e6420746865207461626c657320696e206d657461646174612f2e0a2a210a2a212046726f6d20746865206465706f73697420666f6c6465723a2020202020646f2073657475702f5f5f444154415345545f5f5f73657475702e646f0a2a212046726f6d20616e7977686572653a202020202020202020202020202020646f20223c6465706f7369743e2f73657475702f5f5f444154415345545f5f5f73657475702e646f2220223c6465706f7369743e220a2a2120416c736f20736176652061202e6474613a202020202020202020202020646f2073657475702f5f5f444154415345545f5f5f73657475702e646f202e20225f5f444154415345545f5f2e647461220a2a210a2a21204e65656473205374617461203136206f72206e6577657220616e64206e6f20757365722d7772697474656e20636f6d6d616e64732e205265706c6163657320746865206461746120696e0a2a21206d656d6f72792e204576657279206c6162656c2c2076616c7565206c6162656c2c20666f726d61742c2073746f7261676520747970652c206e6f74652c20616e640a2a2120636861726163746572697374696320636f6d65732066726f6d20746865206d65746164617461207461626c65732c20736f20796f752063616e20656469742074686f7365207461626c65730a2a212028696e20457863656c206f7220616e7920656469746f722920616e6420726572756e20746869732066696c652e0a0a696620632873746174615f76657273696f6e29203c203136207b0a202020206469206173206572722022546869732073657475702066696c65206e65656473205374617461203136206f72206e657765723b20746869732069732053746174612060632873746174615f76657273696f6e29272e220a2020202064692061732065727220222020496e205374617461203134206f722031352c206f70656e20646174612f5f5f444154415345545f5f2e647461206469726563746c793a20697420686f6c6473207468652073616d65206461746120616e64206c6162656c732e220a2020202064692061732065727220222020496e205374617461203133206f72206f6c6465722c20696d706f727420646174612f5f5f444154415345545f5f2e637376207769746820696e7368656574206f7220696d706f72742064656c696d6974656420616e642074616b65220a20202020646920617320"
        h = h + "657272202220206c6162656c732066726f6d206d657461646174612f5f5f444154415345545f5f5f7661726961626c65732e63737620616e64206d657461646174612f5f5f444154415345545f5f5f76616c75656c6162656c732e6373762e220a202020206578697420390a7d0a76657273696f6e2031360a6172677320726f6f74207361766561730a6c6f63616c20647320225f5f444154415345545f5f220a6c6f63616c20766162203d206328766172616262726576290a73657420766172616262726576206f66660a0a2a202d2d2d2d2066696e6420746865206465706f73697420666f6c646572202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a696620602260726f6f74272227203d3d202222207c20602260726f6f74272227203d3d20222e22207b0a202020206c6f63616c20726f6f740a20202020666f72656163682074727920696e20222e2220222e2e22207b0a20202020202020206361707475726520636f6e6669726d2066696c6520602260747279272f6d657461646174612f606473275f7661726961626c65732e63737622270a20202020202020206966205f7263203d3d2030202620602260726f6f74272227203d3d202222206c6f63616c20726f6f74206022607472792722270a202020207d0a20202020696620602260726f6f74272227203d3d202222207b0a2020202020202020646920617320657272202273657475703a2063616e6e6f742066696e64206d657461646174612f606473275f7661726961626c65732e637376220a202020202020202064692061732065727220222020636420746f20746865206465706f73697420666f6c6465722c206f7220706173732069747320706174682061732074686520666972737420617267756d656e74220a2020202020202020736574207661726162627265762060766162270a202020202020202065786974203630310a202020207d0a7d0a666f7265616368206620696e207661726961626c65732076616c75656c6162656c732063686172732064617461736574207b0a202020206361707475726520636f6e6669726d2066696c6520602260726f6f74272f6d657461646174612f606473275f6066272e63737622270a202020206966205f7263207b0a202020202020202064692061732065727220602273657475703a206d697373696e672060726f6f74272f6d657461646174612f606473275f6066272e63737622270a2020202020202020736574207661726162627265762060766162270a202020202020202065786974203630310a202020207d0a7d0a6361707475726520636f6e6669726d2066696c6520"
        h = h + "602260726f6f74272f646174612f606473272e63737622270a6966205f7263207b0a2020202064692061732065727220602273657475703a206d697373696e672060726f6f74272f646174612f606473272e63737622270a20202020736574207661726162627265762060766162270a2020202065786974203630310a7d0a0a6c6f63616c206d6f707473207661726e616d657328312920636173652870726573657276652920656e636f64696e6728227574662d3822292062696e6471756f7465732873747269637429202f2f2f0a202020206d617871756f746564726f777328756e6c696d697465642920737472696e67636f6c73285f616c6c292064656c696d697465727328222c222920636c6561720a0a2a202d2d2d2d207265616420746865206d65746164617461207461626c657320696e746f2074656d706f72617279206672616d6573202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a74656d706e616d6520465620464c2046432046440a666f7265616368207061697220696e202260465627207661726961626c657322202260464c272076616c75656c6162656c732220226046432720636861727322202260464427206461746173657422207b0a20202020676574746f6b656e20667220746162203a20706169720a202020206c6f63616c20746162203d207374727472696d28602260746162272227290a202020206672616d652063726561746520606672270a202020206672616d6520606672273a2071756965746c7920696d706f72742064656c696d69746564207573696e6720602260726f6f74272f6d657461646174612f606473275f60746162272e63737622272c20606d6f707473270a7d0a0a6672616d652060465627207b0a202020206c6f63616c204b203d205f4e0a202020206c6f63616c206e756d636f6c730a202020206c6f63616c20737472636f6c730a20202020666f7276616c7565732069203d20312f604b27207b0a20202020202020206966206b696e645b6069275d203d3d20226e756d6572696322206c6f63616c206e756d636f6c7320606e756d636f6c7327206069270a2020202020202020656c7365206c6f63616c20737472636f6c732060737472636f6c7327206069270a202020207d0a7d0a0a2a202d2d2d2d2072656164207468652064617461202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a6c6f63616c20646f707473207661726e616d657328312920636173652870726573657276652920656e636f64696e6728227574662d3822292062696e6471756f7465732873747269637429202f2f"
        h = h + "2f0a202020206d617871756f746564726f777328756e6c696d69746564292064656c696d697465727328222c2229206173646f75626c6520636c6561720a69662022606e756d636f6c73272220213d202222206c6f63616c20646f7074732060646f70747327206e756d65726963636f6c7328606e756d636f6c7327290a6966202260737472636f6c73272220213d202222206c6f63616c20646f7074732060646f7074732720737472696e67636f6c732860737472636f6c7327290a71756965746c7920696d706f72742064656c696d69746564207573696e6720602260726f6f74272f646174612f606473272e63737622272c2060646f707473270a0a69662063286b2920213d20604b27207b0a20202020646920617320657272202273657475703a20646174612f606473272e63737620686173206063286b292720636f6c756d6e732062757420746865207661726961626c6573207461626c65206c6973747320604b27220a20202020736574207661726162627265762060766162270a2020202065786974203435390a7d0a0a2a202d2d2d2d206e616d65733a2072656e616d6520627920706f736974696f6e202874776f2070617373657320736f206e616d65732063616e6e6f7420636f6c6c69646529202d2d2d2d2d2d2d2d0a6c6f63616c206a20300a666f72656163682076206f66207661726c697374205f616c6c207b0a202020206c6f63616c202b2b6a0a2020202074656d7076617220686f6c640a2020202072656e616d65206076272060686f6c64270a202020206c6f63616c20686f6c645f606a272060686f6c64270a7d0a6c6f63616c206f726465720a666f7276616c756573206a203d20312f604b27207b0a202020206c6f63616c206e6d203d205f667276616c28604656272c2073746174615f6e616d652c20606a27290a2020202072656e616d652060686f6c645f606a272720606e6d270a202020206c6f63616c206f7264657220606f726465722720606e6d270a202020202a2061206e616d652074686174206973206e6f7420612076616c6964205374617461206e616d65206973206b65707420696e20612063686172616374657269737469630a202020206c6f63616c206f726967203d205f667276616c28604656272c206e616d652c20606a27290a202020206d6174613a2073745f6c6f63616c282272656e616d6564222c207374726f667265616c2873745f6c6f63616c28226f726967222920213d2073745f6c6f63616c28226e6d222929290a202020206966206072656e616d656427206d6174613a2073745f676c6f62616c2873745f6c6f63616c28226e6d2229202b20225b646174616465706f7369745f6e616d655d222c2073745f"
        h = h + "6c6f63616c28226f7269672229290a7d0a0a2a202d2d2d2d2074797065732c2064617465732c20666f726d6174732c206c6162656c73202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a6c6f63616c206e6c616220300a666f7276616c756573206a203d20312f604b27207b0a202020206c6f63616c2076202020203d205f667276616c28604656272c2073746174615f6e616d652c20606a27290a202020206c6f63616c2074797020203d205f667276616c28604656272c2073746174615f747970652c20606a27290a202020206c6f63616c206b696e64203d205f667276616c28604656272c206b696e642c20606a27290a202020206c6f63616c20666d7420203d205f667276616c28604656272c20666f726d61742c20606a27290a202020206c6f63616c20766c2020203d205f667276616c28604656272c2076616c75655f6c6162656c732c20606a27290a20202020696620696e6c6973742822606b696e6427222c202264617465222c20226461746574696d652229207b0a202020202020202074656d7076617220740a202020202020202069662022606b696e642722203d3d20226461746522207b0a20202020202020202020202071756965746c792067656e20646f75626c6520607427203d20636f6e6428737562737472286076272c20312c203129203d3d20222e222c207265616c28607627292c2064617465286076272c2022594d442229290a20202020202020207d0a2020202020202020656c736520696620737562737472282260666d7427222c20312c203329203d3d202225744322207b0a20202020202020202020202071756965746c792067656e20646f75626c6520607427203d20636f6e6428737562737472286076272c20312c203129203d3d20222e222c207265616c28607627292c20436c6f636b286076272c2022594d44686d732229290a20202020202020207d0a2020202020202020656c7365207b0a20202020202020202020202071756965746c792067656e20646f75626c6520607427203d20636f6e6428737562737472286076272c20312c203129203d3d20222e222c207265616c28607627292c20636c6f636b286076272c2022594d44686d732229290a20202020202020207d0a202020202020202071756965746c7920636f756e74206966206d697373696e67286074272920262060762720213d202222202620737562737472286076272c20312c20312920213d20222e220a202020202020202069662072284e29207b0a202020202020202020202020646920617320657272202273657475703a2060762720686173206072284e29272076616c7565732074686174"
        h = h + "20617265206e6f742076616c696420606b696e642773220a202020202020202020202020736574207661726162627265762060766162270a20202020202020202020202065786974203435390a20202020202020207d0a202020202020202064726f70206076270a202020202020202072656e616d6520607427206076270a202020207d0a2020202069662022606b696e642722203d3d2022737472696e6722207b0a20202020202020202a20696d706f72742064656c696d69746564207475726e73205c725c6e20696e736964652071756f746564207465787420696e746f205c723b20726573746f72652069740a202020202020202071756965746c79207265706c61636520607627203d20737562696e737472286076272c2063686172283133292c206368617228313329202b2063686172283130292c202e2920696620737472706f73286076272c206368617228313329290a202020207d0a2020202069662022607479702722203d3d2022666c6f6174222071756965746c792072656361737420666c6f6174206076272c20666f7263650a20202020656c73652071756965746c7920726563617374206074797027206076270a20202020666f726d6174206076272060666d74270a202020202a20736574206576657279206c6162656c2c206576656e20616e20656d707479206f6e653a20696d706f72742064656c696d69746564207075747320746865206f726967696e616c0a202020202a20636f6c756d6e206e616d6520696e20746865206c6162656c206f6620616e7920636f6c756d6e2069742068616420746f2072656e616d650a202020206c6f63616c206c6162203d205f667276616c28604656272c206c6162656c2c20606a27290a202020206d6174613a2073745f7661726c6162656c2873745f6c6f63616c28227622292c20757375627374722873745f6c6f63616c28226c616222292c20312c20383029290a202020206d6174613a2073745f6c6f63616c28226c6c656e222c207374726f667265616c28757374726c656e2873745f6c6f63616c28226c616222292929290a20202020696620606c6c656e27203e203830207b0a20202020202020206d6174613a2073745f676c6f62616c2873745f6c6f63616c2822762229202b20225b646174616465706f7369745f6c6162656c5d222c2073745f6c6f63616c28226c61622229290a202020207d0a20202020696620606c6c656e27203e2030206c6f63616c202b2b6e6c61620a202020206966202260766c272220213d202222206c6162656c2076616c756573206076272060766c270a7d0a6f7264657220606f72646572270a0a2a202d2d2d2d2076616c7565206c6162656c73202d2d2d2d2d2d2d"
        h = h + "2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a6672616d652060464c273a206c6f63616c204e4c203d205f4e0a666f7276616c7565732069203d20312f604e4c27207b0a202020206c6f63616c20736574203d205f667276616c2860464c272c207365742c20606927290a202020206c6f63616c2076616c203d205f667276616c2860464c272c2076616c75652c20606927290a202020206c6f63616c20747874203d205f667276616c2860464c272c206c6162656c2c20606927290a202020206d6174613a2073745f766c6d6f646966792873745f6c6f63616c282273657422292c20737472746f7265616c2873745f6c6f63616c282276616c2229292c2073745f6c6f63616c28227478742229290a7d0a0a2a202d2d2d2d206368617261637465726973746963732028696e636c75646573206e6f74657320616e64206c6162656c206c616e67756167657329202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a6672616d6520604643273a206c6f63616c204e43203d205f4e0a6c6f63616c206e6c6f6e6720300a666f7276616c7565732069203d20312f604e4327207b0a202020206c6f63616c20637620203d205f667276616c28604643272c207661726961626c652c20606927290a202020206c6f63616c20636e20203d205f667276616c28604643272c20636861722c20606927290a202020206c6f63616c20747874203d205f667276616c28604643272c20746578742c20606927290a202020206d6174613a2073745f6c6f63616c2822636c656e222c207374726f667265616c287374726c656e2873745f6c6f63616c282274787422292929290a2020202069662060636c656e27203e203637373833207b0a20202020202020202a205374617461206b65657073206174206d6f73742036372c3738332062797465733b20637574206f6e20612063686172616374657220626f756e646172790a20202020202020206c6f63616c202b2b6e6c6f6e670a20202020202020206d6174613a205f5f64645f73203d20757375627374722873745f6c6f63616c282274787422292c20312c203637373833293b207768696c6520287374726c656e285f5f64645f7329203e20363737383329205f5f64645f73203d2075737562737472285f5f64645f732c20312c20757374726c656e285f5f64645f7329202d2031293b2073745f676c6f62616c2873745f6c6f63616c282263762229202b20225b22202b2073745f6c6f63616c2822636e2229202b20225d222c205f5f64645f73290a20202020202020206d6174613a206d6174612064726f70205f5f64645f730a202020207d0a2020"
        h = h + "2020656c7365207b0a20202020202020206d6174613a2073745f676c6f62616c2873745f6c6f63616c282263762229202b20225b22202b2073745f6c6f63616c2822636e2229202b20225d222c2073745f6c6f63616c28227478742229290a202020207d0a7d0a696620606e6c6f6e6727207b0a20202020646920617320747874202273657475703a206e6f74653a20606e6c6f6e67272063686172616374657269737469632873292065786365656420537461746127732036372c3738332d62797465206c696d697420616e642077657265206375743b220a202020206469206173207478742022202020202020207468652066756c6c207465787420697320696e206d657461646174612f606473275f63686172732e637376220a7d0a0a2a202d2d2d2d2064617461736574206c6162656c20616e6420736f7274206f72646572202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a6672616d652060464427207b0a202020206c6f63616c20646c61620a202020206c6f63616c20736f727462790a20202020666f7276616c7565732069203d20312f603d5f4e27207b0a20202020202020206966206b65795b6069275d203d3d20226c6162656c22202020206c6f63616c20646c6162203d2076616c75655b6069275d0a20202020202020206966206b65795b6069275d203d3d2022736f72746564627922206c6f63616c20736f72746279203d2076616c75655b6069275d0a202020207d0a7d0a2a206c6162656c2064617461206b6565707320646f6c6c6172207369676e732c206261636b7469636b7320616e642071756f746573207768656e20746865206d6163726f20697320706173736564207468726f7567680a2a206d616376616c20696e7369646520636f6d706f756e642071756f7465733b206f6e6c79207468652074776f2d6368617261637465722073657175656e636520222720627265616b732069742c0a2a20736f206f6e206661696c75726520746861742073657175656e63652067657473206120737061636520616e6420746865206368616e6765206973207265706f727465640a6d6174613a2073745f6c6f63616c2822646c656e222c207374726f667265616c287374726c656e2873745f6c6f63616c2822646c616222292929290a69662060646c656e27203e2030207b0a2020202063617074757265206c6162656c2064617461206022606d616376616c28646c6162292722270a202020206966205f7263207b0a20202020202020206d6174613a2073745f6c6f63616c2822646c6162222c20737562696e7374722873745f6c6f63616c2822646c616222292c206368617228333429"
        h = h + "202b2063686172283339292c206368617228333429202b20222022202b20636861722833392929290a202020202020202063617074757265206c6162656c2064617461206022606d616376616c28646c6162292722270a20202020202020206966205f726320646920617320747874202273657475703a206e6f74653a207468652064617461736574206c6162656c20636f756c64206e6f74206265207365743b20697420697320696e206d657461646174612f606473275f646174617365742e637376220a2020202020202020656c736520646920617320747874202273657475703a206e6f74653a20612073706163652077617320616464656420696e73696465207468652064617461736574206c6162656c20736f20537461746120636f756c642073746f7265206974220a202020207d0a7d0a6966202260736f72746279272220213d20222220736f72742060736f72746279272c20737461626c650a0a666f726561636820667220696e20604656272060464c2720604643272060464427207b0a2020202063617074757265206672616d652064726f7020606672270a7d0a736574207661726162627265762060766162270a0a646920617320747874202273657475703a206275696c7420222061732072657320226064732722206173207478742022202822206173207265732063284e29206173207478742022206f62732c2022202f2f2f0a202020206173207265732063286b2920617320747874202220766172732c20222061732072657320606e6c616227206173207478742022207661726961626c65206c6162656c732c2022202f2f2f0a2020202061732072657320604e4c272061732074787420222076616c7565206c6162656c732c20222061732072657320604e43272061732074787420222063686172616374657269737469637329220a0a69662060226073617665617327222720213d202222207b0a2020202073617665206022607361766561732722272c207265706c6163650a7d0a"
    }
    if (which == "R") {
        h = h + "2320646174616465706f7369742073657475702066696c6520666f72205220286465706f736974207370656320312e30290a232052656275696c64732064617461736574205f5f444154415345545f5f2066726f6d20646174612f5f5f444154415345545f5f2e63737620616e6420746865207461626c657320696e206d657461646174612f2e0a230a2320496e20522c2066726f6d20746865206465706f73697420666f6c6465723a0a232020202020736f75726365282273657475702f5f5f444154415345545f5f5f73657475702e522229202020202020232063726561746573207468652064617461206672616d6520605f5f444154415345545f5f600a2320202020206466203c2d20736f75726365282273657475702f5f5f444154415345545f5f5f73657475702e5222292476616c75650a232046726f6d20616e79776865726520696e20523a0a2320202020206f7074696f6e7328646174616465706f7369742e726f6f74203d20223c6465706f7369743e22293b20736f7572636528223c6465706f7369743e2f73657475702f5f5f444154415345545f5f5f73657475702e5222290a232046726f6d2061207368656c6c3a0a232020202020527363726970742073657475702f5f5f444154415345545f5f5f73657475702e52205b2d2d726f6f74204449525d205b2d2d736176652d7264732046494c455d205b2d2d736176652d7361762046494c455d0a230a23204e656564732062617365205220332e35206f72206e6577657220616e64206e6f7468696e6720656c73652e20457874656e646564206d697373696e6720636f64657320282e6120746f0a23202e7a29206265636f6d6520746167676564204e4173207468617420686176656e3a3a6e615f74616728292063616e20726561642e205768656e2074686520686176656e207061636b6167650a2320697320696e7374616c6c65642c206c6162656c6c6564207661726961626c657320616c736f206765742074686520686176656e5f6c6162656c6c656420636c6173733b207365740a23206f7074696f6e7328646174616465706f7369742e686176656e203d2046414c53452920746f206b65657020706c61696e20766563746f72732c20616e64206f7074696f6e7328646174616465706f7369742e65786163745f646f75626c6573203d2046414c53452920746f0a2320736b6970207468652065786163742d646f75626c6520636865636b2028666173746572206f6e206269672066696c65733b207365652062656c6f77292e204576657279206c6162656c2c2076616c7565206c6162656c2c206e6f74652c20616e642063686172616374657269737469630a2320636f6d65732066726f6d2074"
        h = h + "6865206d65746164617461207461626c65732c20736f20796f752063616e20656469742074686f7365207461626c657320616e6420726572756e2e0a0a6c6f63616c287b0a20206473203c2d20225f5f444154415345545f5f220a202061726773203c2d20636f6d6d616e644172677328747261696c696e674f6e6c79203d2054525545290a202061726776616c203c2d2066756e6374696f6e28666c616729207b0a2020202069203c2d206d6174636828666c61672c2061726773290a202020206966202869732e6e61286929207c7c2069203d3d206c656e67746828617267732929204e554c4c20656c736520617267735b5b69202b20315d5d0a20207d0a0a202023202d2d2d2d2066696e6420746865206465706f73697420666f6c646572202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a20206861735f6d657461203c2d2066756e6374696f6e28646972292066696c652e6578697374732866696c652e70617468286469722c20226d65746164617461222c207061737465302864732c20225f7661726961626c65732e637376222929290a2020726f6f74203c2d2061726776616c28222d2d726f6f7422290a20206966202869732e6e756c6c28726f6f74292920726f6f74203c2d206765744f7074696f6e2822646174616465706f7369742e726f6f7422290a20206966202869732e6e756c6c28726f6f742929207b0a2020202068657265203c2d204e554c4c0a202020206661203c2d206772657028225e2d2d66696c653d222c20636f6d6d616e64417267732846414c5345292c2076616c7565203d2054525545290a20202020696620286c656e67746828666129292068657265203c2d206469726e616d65286e6f726d616c697a65506174682873756228225e2d2d66696c653d222c2022222c2066615b315d2929290a20202020666f722028667220696e20726576287379732e6672616d657328292929207b0a202020202020696620282169732e6e756c6c286672246f66696c652929207b2068657265203c2d206469726e616d65286e6f726d616c697a6550617468286672246f66696c6529293b20627265616b207d0a202020207d0a20202020666f72202863616e6420696e206328696620282169732e6e756c6c28686572652929206469726e616d652868657265292c20222e222c20222e2e222929207b0a202020202020696620286861735f6d6574612863616e642929207b20726f6f74203c2d2063616e643b20627265616b207d0a202020207d0a20207d0a20206966202869732e6e756c6c28726f6f7429207c7c20216861735f6d65746128726f6f742929207b0a20202020"
        h = h + "73746f70282273657475703a2063616e6e6f742066696e64206d657461646174612f222c2064732c20225f7661726961626c65732e6373763b20222c0a202020202020202020227365747764282920746f20746865206465706f73697420666f6c646572206f7220736574206f7074696f6e7328646174616465706f7369742e726f6f74203d202e2e2e29222c2063616c6c2e203d2046414c5345290a20207d0a0a20207264203c2d2066756e6374696f6e287061746829207b0a202020207574696c733a3a726561642e63737628706174682c20636f6c436c6173736573203d2022636861726163746572222c206e612e737472696e6773203d206368617261637465722830292c0a2020202020202020202020202020202020202020636865636b2e6e616d6573203d2046414c53452c20737472696e67734173466163746f7273203d2046414c53452c2066696c65456e636f64696e67203d20225554462d3822290a20207d0a20206d657461203c2d2066756e6374696f6e2874616229207b0a2020202066203c2d2066696c652e7061746828726f6f742c20226d65746164617461222c207061737465302864732c20225f222c207461622c20222e6373762229290a20202020696620282166696c652e657869737473286629292073746f70282273657475703a206d697373696e6720222c20662c2063616c6c2e203d2046414c5345290a2020202072642866290a20207d0a202076617273203c2d206d65746128227661726961626c657322290a2020766c2020203c2d206d657461282276616c75656c6162656c7322290a202063682020203c2d206d6574612822636861727322290a202064736d20203c2d206d65746128226461746173657422290a2020646b6579203c2d2066756e6374696f6e286b29207b2076203c2d2064736d2476616c75655b64736d246b6579203d3d206b5d3b20696620286c656e6774682876292920765b5b315d5d20656c7365202222207d0a20204b203c2d206e726f772876617273290a0a202023202d2d2d2d2072656164207468652064617461202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a20206466696c65203c2d2066696c652e7061746828726f6f742c202264617461222c207061737465302864732c20222e6373762229290a2020696620282166696c652e657869737473286466696c6529292073746f70282273657475703a206d697373696e6720222c206466696c652c2063616c6c2e203d2046414c5345290a20202320696e7465676572732070617273652065786163746c7920696e206261736520523b20646f75626c65"
        h = h + "7320616e6420666c6f617473206172652072656164206173207465787420616e640a20202320636f6e7665727465642062656c6f772c2062656361757365206261736520522773207061727365722063616e206d69737320746865206c6173742062696e6172792064696769740a2020636c73203c2d206966656c73652876617273246b696e64203d3d20226e756d65726963222026207661727324657874656e6465645f6d697373696e6720213d2022312220260a202020202020202020202020202020202020766172732473746174615f747970652025696e252063282262797465222c2022696e74222c20226c6f6e6722292c20226e756d65726963222c202263686172616374657222290a20202320726561642e637376207475726e7320612063617272696167652072657475726e20696e736964652071756f746564207465787420696e746f206e6f7468696e672c20736f207768656e0a202023207468652066696c6520686173206f6e652028646174616465706f73697420777269746573205c6e206c696e6520656e64696e67732c20736f20616e79205c7220697320696e736964650a202023207465787429207377617020697420666f72206120706c616365686f6c64657220616e6420707574206974206261636b2061667465722070617273696e670a20206861735f6372203c2d2046414c53450a202073656e74203c2d204e554c4c0a2020636f6e203c2d2066696c65286466696c652c2022726222290a2020726570656174207b0a202020206368756e6b203c2d207265616442696e28636f6e2c2022726177222c203634202a20313032345e32290a2020202069662028216c656e677468286368756e6b292920627265616b0a2020202069662028616e79286368756e6b203d3d2061732e726177283133292929207b206861735f6372203c2d20545255453b20627265616b207d0a20207d0a2020636c6f736528636f6e290a2020696620286861735f63722026262066696c652e73697a65286466696c6529203c2031653929207b0a20202020747874203c2d207265616443686172286466696c652c2066696c652e73697a65286466696c65292c207573654279746573203d2054525545290a20202020456e636f64696e672874787429203c2d20225554462d38220a2020202073656e74203c2d20225c7545304344220a202020207768696c652028677265706c2873656e742c207478742c206669786564203d205452554529292073656e74203c2d207061737465302873656e742c20225c754530434522290a20202020747874203c2d206773756228225c72222c2073656e742c207478742c206669786564203d2054525545290a2020202064203c2d"
        h = h + "207574696c733a3a726561642e6373762874657874203d207478742c20636f6c436c6173736573203d20756e6e616d6528636c73292c206e612e737472696e6773203d206368617261637465722830292c0a20202020202020202020202020202020202020202020202020636865636b2e6e616d6573203d2046414c53452c20737472696e67734173466163746f7273203d2046414c53452c20656e636f64696e67203d20225554462d3822290a20202020726d28747874290a20202020666f7220286a20696e207365715f616c6f6e6728642929207b0a2020202020206966202869732e63686172616374657228645b5b6a5d5d292920645b5b6a5d5d203c2d20677375622873656e742c20225c72222c20645b5b6a5d5d2c206669786564203d2054525545290a202020207d0a20207d20656c7365207b0a20202020696620286861735f637229206d657373616765282273657475703a206e6f74653a2066696c6573206f7665722031204742206172652072656164206469726563746c792c20736f2063617272696167652072657475726e7320696e736964652074657874206172652064726f7070656422290a2020202064203c2d207574696c733a3a726561642e637376286466696c652c20636f6c436c6173736573203d20756e6e616d6528636c73292c206e612e737472696e6773203d206368617261637465722830292c0a20202020202020202020202020202020202020202020202020636865636b2e6e616d6573203d2046414c53452c20737472696e67734173466163746f7273203d2046414c53452c2066696c65456e636f64696e67203d20225554462d3822290a20207d0a2020696620286e636f6c28642920213d204b29207b0a2020202073746f70282273657475703a20222c206466696c652c20222068617320222c206e636f6c2864292c202220636f6c756d6e732062757420746865207661726961626c6573207461626c65206c6973747320222c204b2c2063616c6c2e203d2046414c5345290a20207d0a20206e616d6573286429203c2d2076617273246e616d650a0a20207573655f686176656e203c2d20697354525545286765744f7074696f6e2822646174616465706f7369742e686176656e222c205452554529292026260a20202020726571756972654e616d6573706163652822686176656e222c2071756965746c79203d2054525545290a202069735f746167203c2d2066756e6374696f6e28782920677265706c28225e5c5c2e5b612d7a5d24222c2078290a202073657473203c2d2073706c697428766c5b63282276616c7565222c20226c6162656c22295d2c20666163746f7228766c247365742c206c6576656c73203d20756e6971"
        h = h + "756528766c247365742929290a20207365745f766563746f72203c2d2066756e6374696f6e287329207b0a2020202023206e756d65726963206c6162656c732061732061206e616d6564206e756d6572696320766563746f723b20657874656e64656420636f646573206b6570742061706172740a20202020657874203c2d2069735f74616728732476616c7565290a202020206c697374286e756d203d2073746174733a3a7365744e616d65732861732e6e756d6572696328732476616c75655b216578745d292c2073246c6162656c5b216578745d292c0a202020202020202020657874203d2073746174733a3a7365744e616d657328732476616c75655b6578745d2c2073246c6162656c5b6578745d29290a20207d0a20207163686172203c2d20646b657928227175657374696f6e5f6368617222290a202063686172735f666f72203c2d2066756e6374696f6e287629207b0a20202020726f7773203c2d2063685b6368247661726961626c65203d3d20762c202c2064726f70203d2046414c53455d0a2020202069736e6f7465203c2d20677265706c28225e6e6f74655b302d395d2b24222c20726f77732463686172290a202020206e6e203c2d20726f77735b69736e6f7465202620726f7773246368617220213d20226e6f746530222c202c2064726f70203d2046414c53455d0a202020206e6e203c2d206e6e5b6f726465722861732e696e74656765722873756228225e6e6f7465222c2022222c206e6e24636861722929292c202c2064726f70203d2046414c53455d0a202020206f74686572203c2d20726f77735b2169736e6f746520262021726f777324636861722025696e2520632822646174616465706f7369745f6c6162656c222c2022646174616465706f7369745f6e616d6522292c202c2064726f70203d2046414c53455d0a202020206c697374286e6f746573203d206e6e24746578742c206368617273203d2073746174733a3a7365744e616d6573286f7468657224746578742c206f74686572246368617229290a20207d0a0a202023203e3e3e2065786163742d646f75626c652028746f6f6c732f73796e635f74656d706c617465732e707920636f70696573207468697320626c6f636b20696e746f207468652052207061636b616765290a202023205468652063737620686f6c647320657665727920646f75626c6520776974682061626f7574203137207369676e69666963616e74206469676974732e2042617365205227730a20202320706172736572206973206e6f7420636f72726563746c7920726f756e6465642c20736f206561636820646f75626c6520697320636865636b656420616761696e737420697473206f776e0a2020"
        h = h + "23207465787420616e64206d6f76656420746f2074686520646f75626c652077686f736520657861637420646563696d616c20657870616e73696f6e2028746f20323020646967697473290a20202320697320636c6f7365737420746f207468617420746578742e0a20207369673137203c2d2066756e6374696f6e287a29207b0a202020207a203c2d2073756228225e5b2d2b5d222c2022222c207a290a202020206861735f65203c2d20677265706c28225b65455d222c207a290a202020206578203c2d20696e7465676572286c656e677468287a29290a2020202065785b6861735f655d203c2d2061732e696e74656765722873756228225e2e2a5b65455d222c2022222c207a5b6861735f655d29290a202020206d203c2d2073756228225b65455d2e2a24222c2022222c207a290a202020206970203c2d2073756228225c5c2e2e2a24222c2022222c206d290a202020206670203c2d206966656c736528677265706c28222e222c206d2c206669786564203d2054525545292c2073756228225e5b5e2e5d2a5c5c2e222c2022222c206d292c202222290a202020206467203c2d207061737465302869702c206670290a202020206c7a203c2d206e6368617228646729202d206e636861722873756228225e302b222c2022222c20646729290a202020206467203c2d2073756228225e302b222c2022222c206467290a202020206c6973742864203d20737562737472287061737465302864672c20737472726570282230222c20323029292c20312c203230292c2065203d206578202b206e6368617228697029202d206c7a202d20314c290a20207d0a2020736967313779203c2d2066756e6374696f6e287929207b0a202020207a203c2d20737072696e74662822252e313965222c20616273287929290a202020206c6973742864203d2070617374653028737562737472287a2c20312c2031292c20737562737472287a2c20332c20323129292c2065203d2061732e696e74656765722873756228225e2e2a65222c2022222c207a2929290a20207d0a2020736869667431203c2d2066756e6374696f6e287829206c6973742864203d20706173746530282230222c20737562737472287824642c20312c20313929292c2065203d20782465202b20314c290a2020676170203c2d2066756e6374696f6e28612c206229207b0a2020202070617274203c2d2066756e6374696f6e28782c20662c206c292061732e6e756d657269632873756273747228782c20662c206c29290a202020206c6f203c2d20612465203d3d20622465202b20314c0a202020206869203c2d20622465203d3d20612465202b20314c0a202020206232203c2d207368696674312862290a2020"
        h = h + "20206132203c2d207368696674312861290a202020206264203c2d206966656c7365286c6f2c20623224642c20622464290a202020206164203c2d206966656c73652868692c20613224642c20612464290a2020202067203c2d2028706172742861642c20312c203829202d20706172742862642c20312c20382929202a2031653132202b2028706172742861642c20392c20313629202d20706172742862642c20392c2031362929202a20316534202b0a20202020202028706172742861642c2031372c20323029202d20706172742862642c2031372c20323029290a20202020675b61627328612465202d2062246529203e20314c5d203c2d204e410a20202020670a20207d0a202065786163745f646f75626c65203c2d2066756e6374696f6e287478742c207929207b0a202020202320696e746567657220746578742062656c6f7720325e353320616c77617973207061727365732065786163746c793b20636865636b2065766572797468696e6720656c73650a20202020696e745f747874203c2d2021677265706c28225b2e65455d222c20747874290a2020202069203c2d207768696368282169732e6e6128792920262069732e66696e6974652879292026207920213d20302026202128696e745f747874202620616273287929203c20325e353329290a2020202069662028216c656e677468286929292072657475726e2879290a2020202023206661737420706174683a20646174616465706f7369742077726974657320646f75626c657320617320252e3137672074657874202853746174612064726f7073207468650a2020202023206c656164696e67207a65726f292c20736f2074686520726967687420646f75626c65207072696e7473206261636b20746f207468652073616d6520746578743b20610a2020202023206d69737265616420697320616c6d6f737420616c77617973206f6e6520756e697420696e20746865206c61737420706c616365206f66660a202020206e6f726d203c2d2066756e6374696f6e287a292073756228225e282d3f29305b2e5d222c20225c5c312e222c207a290a202020207474203c2d206e6f726d287478745b695d290a202020207969203c2d20795b695d0a202020206a203c2d207768696368286e6f726d28737072696e74662822252e313767222c207969292920213d207474290a20202020666f7220286b20696e206328312c202d312929207b0a20202020202069662028216c656e677468286a292920627265616b0a20202020202063616e64203c2d2079695b6a5d202b206b202a20325e28666c6f6f72286c6f6732286162732879695b6a5d292929202d203532290a202020202020686974203c2d206e6f72"
        h = h + "6d28737072696e74662822252e313767222c2063616e642929203d3d2074745b6a5d0a20202020202079695b6a5b6869745d5d203c2d2063616e645b6869745d0a2020202020206a203c2d206a5b216869745d0a202020207d0a20202020795b695d203c2d2079690a2020202069662028216c656e677468286a29292072657475726e2879290a2020202072657374203c2d20695b6a5d0a20202020795b726573745d203c2d2065786163745f736c6f77287478745b726573745d2c20795b726573745d290a20202020790a20207d0a202065786163745f736c6f77203c2d2066756e6374696f6e287478742c207929207b0a2020202069203c2d207365715f616c6f6e672879290a2020202077203c2d207369673137287478745b695d290a202020207969203c2d20795b695d0a20202020616374203c2d207365715f616c6f6e67287969290a20202020666f7220286974657220696e20313a3429207b0a20202020202069662028216c656e67746828616374292920627265616b0a2020202020207761203c2d206c6973742864203d207724645b6163745d2c2065203d207724655b6163745d290a20202020202070203c2d207369673137792879695b6163745d290a20202020202067203c2d206761702877612c2070290a202020202020666172203c2d2069732e6e612867290a20202020202069662028616e79286661722929207b0a202020202020202072203c2d2061732e6e756d657269632873756273747228776124645b6661725d2c20312c2031352929202f2061732e6e756d6572696328737562737472287024645b6661725d2c20312c20313529290a202020202020202079695b6163745b6661725d5d203c2d2079695b6163745b6661725d5d202a2072202a2031305e28776124655b6661725d202d207024655b6661725d290a2020202020207d0a202020202020626967203c2d2021666172202620616273286729203e20333030300a20202020202079695b6163745b6269675d5d203c2d2079695b6163745b6269675d5d202b207369676e2879695b6163745b6269675d5d29202a2028675b6269675d202a2031652d313929202a2031305e706d617828776124655b6269675d2c207024655b6269675d290a202020202020616374203c2d206163745b666172207c206269675d0a202020207d0a20202020616374203c2d207365715f616c6f6e67287969290a20202020666f7220286974657220696e20313a3629207b0a20202020202069662028216c656e67746828616374292920627265616b0a2020202020207761203c2d206c6973742864203d207724645b6163745d2c2065203d207724655b6163745d290a2020202020207961203c2d2079695b6163"
        h = h + "745d0a202020202020756c70203c2d20325e28666c6f6f72286c6f673228616273287961292929202d203532290a20202020202067203c2d20616273286761702877612c207369673137792879612929290a2020202020206775203c2d20616273286761702877612c20736967313779287961202b20756c702929290a2020202020206764203c2d20616273286761702877612c20736967313779287961202d20756c702929290a2020202020207570203c2d202169732e6e61286775292026202869732e6e61286729207c206775203c2067292026202869732e6e6128676429207c206775203c3d206764290a202020202020646e203c2d202169732e6e61286764292026202869732e6e61286729207c206764203c2067292026202175700a20202020202079695b6163745b75705d5d203c2d2079615b75705d202b20756c705b75705d0a20202020202079695b6163745b646e5d5d203c2d2079615b646e5d202d20756c705b646e5d0a202020202020616374203c2d206163745b7570207c20646e5d0a202020207d0a20202020795b695d203c2d2079690a20202020790a20207d0a202023203c3c3c2065786163742d646f75626c650a202061735f666c6f61743332203c2d2066756e6374696f6e287929207b0a202020206f6b203c2d202169732e6e612879290a20202020795b6f6b5d203c2d207265616442696e28777269746542696e28795b6f6b5d2c2072617728292c2073697a65203d2034292c2022646f75626c65222c2073697a65203d20342c206e203d2073756d286f6b29290a20202020790a20207d0a0a20202320457874656e646564206d697373696e6720636f64657320282e6120746f202e7a2920617265206b65707420696e7369646520746865204e4120697473656c662c20696e207468650a202023206c61796f757420686176656e207573657320666f7220746167676564204e41732c20736f206120636f646520666f6c6c6f77732069747320726f77207468726f75676820616e790a20202320737562736574206f7220736f72742e204275696c74206865726520696e206261736520523b20686176656e3a3a6e615f7461672829207265616473207468652073616d6520626974732e0a20207461675f6e61203c2d2066756e6374696f6e287461677329207b0a2020202062203c2d207265702861732e726177286328307861322c20307830372c20307830302c20307830302c20307830302c20307830302c20307866302c203078376629292c206c656e677468287461677329290a20202020625b73657128352c206279203d20382c206c656e6774682e6f7574203d206c656e677468287461677329295d203c2d2063686172546f52617728"
        h = h + "706173746528746167732c20636f6c6c61707365203d20222229290a202020207265616442696e28622c2022646f75626c65222c206e203d206c656e6774682874616773292c2073697a65203d20382c20656e6469616e203d20226c6974746c6522290a20207d0a0a20206e6c6162203c2d20304c0a2020666f7220286a20696e207365715f6c656e284b2929207b0a2020202076203c2d20766172735b6a2c205d0a2020202078203c2d20645b5b6a5d5d0a20202020657874203c2d204e554c4c0a202020206966202876246b696e6420213d2022737472696e672229207b0a2020202020206966202869732e63686172616374657228782929207b0a20202020202020207467203c2d2069735f7461672878290a202020202020202069662028616e79287467292920657874203c2d2073746174733a3a7365744e616d6573287768696368287467292c2073756273747228785b74675d2c20322c203229290a2020202020202020785b74675d203c2d2022220a2020202020207d0a2020202020206966202876246b696e64203d3d20226e756d65726963222026262069732e63686172616374657228782929207b0a202020202020202079203c2d2073757070726573735761726e696e67732861732e6e756d65726963287829290a2020202020202020626164203c2d2069732e6e612879292026207820213d2022220a202020202020202069662028616e792862616429292073746f70282273657475703a20222c2076246e616d652c202220686173206e6f6e2d6e756d657269632076616c7565732c2066697273743a20222c20785b6261645d5b315d2c2063616c6c2e203d2046414c5345290a202020202020202069662028762473746174615f74797065203d3d2022646f75626c652220262620697354525545286765744f7074696f6e2822646174616465706f7369742e65786163745f646f75626c6573222c20545255452929292079203c2d2065786163745f646f75626c6528782c2079290a202020202020202069662028762473746174615f74797065203d3d2022666c6f617422292079203c2d2061735f666c6f617433322879290a202020202020202078203c2d20790a2020202020207d20656c7365206966202876246b696e64203d3d2022646174652229207b0a202020202020202079203c2d2061732e44617465286966656c73652878203d3d2022222c204e415f6368617261637465725f2c2078292c20666f726d6174203d202225592d256d2d256422290a202020202020202069662028616e792869732e6e612879292026207820213d20222229292073746f70282273657475703a20222c2076246e616d652c2022206861732076616c756573207468"
        h = h + "617420617265206e6f74206461746573222c2063616c6c2e203d2046414c5345290a202020202020202078203c2d20790a2020202020207d20656c7365206966202876246b696e64203d3d20226461746574696d652229207b0a202020202020202079203c2d2061732e504f5349586374286966656c73652878203d3d2022222c204e415f6368617261637465725f2c2078292c20666f726d6174203d202225592d256d2d25642025483a254d3a254f53222c20747a203d202255544322290a202020202020202069662028616e792869732e6e612879292026207820213d20222229292073746f70282273657475703a20222c2076246e616d652c2022206861732076616c756573207468617420617265206e6f74206461746574696d6573222c2063616c6c2e203d2046414c5345290a202020202020202078203c2d20790a2020202020207d0a202020207d0a20202020696620282169732e6e756c6c286578742929207b0a20202020202061203c2d20617474726962757465732878290a20202020202078203c2d2061732e646f75626c6528756e636c617373287829290a202020202020785b6578745d203c2d207461675f6e61286e616d65732865787429290a20202020202061747472696275746573287829203c2d20610a202020207d0a20202020696620286e7a6368617228762476616c75655f6c6162656c7329202626202169732e6e756c6c28736574735b5b762476616c75655f6c6162656c735d5d2929207b0a2020202020207376203c2d207365745f766563746f7228736574735b5b762476616c75655f6c6162656c735d5d290a2020202020206c616273203c2d207376246e756d0a202020202020696620286c656e677468287376246578742929206c616273203c2d2063286c6162732c2073746174733a3a7365744e616d6573287461675f6e6128737562737472287376246578742c20322c203229292c206e616d6573287376246578742929290a2020202020206966202876246b696e64203d3d20226e756d6572696322202626207573655f686176656e292078203c2d20686176656e3a3a6c6162656c6c656428782c206c6162656c73203d206c6162732920656c7365206174747228782c20226c6162656c732229203c2d206c6162730a202020207d0a20202020696620286e7a636861722876246c6162656c2929207b206174747228782c20226c6162656c2229203c2d2076246c6162656c3b206e6c6162203c2d206e6c6162202b20314c207d0a202020206174747228782c2022666f726d61742e73746174612229203c2d207624666f726d61740a202020206366203c2d2063686172735f666f7228762473746174615f6e616d65290a20202020"
        h = h + "696620286c656e677468286366246e6f7465732929206174747228782c20226e6f7465732229203c2d206366246e6f7465730a20202020696620286c656e6774682863662463686172732929206174747228782c202273746174615f63686172732229203c2d2063662463686172730a20202020696620286e7a6368617228716368617229202626202169732e6e612863662463686172735b71636861725d2929206174747228782c20227175657374696f6e2229203c2d20756e6e616d652863662463686172735b71636861725d290a20202020645b5b6a5d5d203c2d20780a20207d0a0a202023202d2d2d2d20646174617365742d6c6576656c2061747472696275746573202d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a20206366203c2d2063686172735f666f7228225f64746122290a2020696620286e7a6368617228646b657928226c6162656c22292929206174747228642c20226c6162656c2229203c2d20646b657928226c6162656c22290a2020696620286c656e677468286366246e6f7465732929206174747228642c20226e6f7465732229203c2d206366246e6f7465730a2020696620286c656e6774682863662463686172732929206174747228642c202273746174615f63686172732229203c2d2063662463686172730a20206174747228642c2022646174616465706f7369742229203c2d206c697374280a2020202064617461736574203d2064732c2073706563203d2022312e30222c20726f6f74203d206e6f726d616c697a655061746828726f6f74292c0a20202020736f727465646279203d20646b65792822736f72746564627922292c0a2020202076616c75655f6c6162656c5f73657473203d206c6170706c7928736574732c2066756e6374696f6e287329207b207376203c2d207365745f766563746f722873293b2063287376246e756d2c20696620286c656e6774682873762465787429292073762465787429207d292c0a202020207661726961626c6573203d20766172732c2076616c75656c6162656c5f726f7773203d20766c2c20636861725f726f7773203d2063682c20646174617365745f7461626c65203d2064736d290a0a20206d657373616765282273657475703a206275696c7420222c2064732c20222028222c206e726f772864292c2022206f62732c20222c204b2c202220766172732c20222c206e6c61622c0a2020202020202020202022207661726961626c65206c6162656c732c20222c206e726f7728766c292c20222076616c7565206c6162656c732c20222c206e726f77286368292c202220636861726163746572697374696373292229"
        h = h + "0a0a20206f7574203c2d2061726776616c28222d2d736176652d72647322290a2020696620282169732e6e756c6c286f75742929207361766552445328642c206f7574290a20206f7574203c2d2061726776616c28222d2d736176652d73617622290a2020696620282169732e6e756c6c286f75742929207b0a202020206966202821726571756972654e616d6573706163652822686176656e222c2071756965746c79203d205452554529292073746f70282273657475703a202d2d736176652d736176206e656564732074686520686176656e207061636b616765222c2063616c6c2e203d2046414c5345290a20202020686176656e3a3a77726974655f73617628642c206f7574290a20207d0a2020736f7572636564203c2d20616e7928766170706c79287379732e6672616d657328292c2066756e6374696f6e28667229202169732e6e756c6c286672246f66696c65292c206c6f676963616c28312929290a20206966202828736f7572636564207c7c20696e74657261637469766528292920262620697354525545286765744f7074696f6e2822646174616465706f7369742e61737369676e222c2054525545292929207b0a2020202061737369676e286d616b652e6e616d6573286473292c20642c20656e766972203d20676c6f62616c656e762829290a20207d0a2020696e76697369626c652864290a7d290a"
    }
    if (which == "py") {
        h = h + "222222646174616465706f7369742073657475702066696c6520666f7220507974686f6e20286465706f736974207370656320312e30292e0a0a52656275696c64732064617461736574205f5f444154415345545f5f2066726f6d20646174612f5f5f444154415345545f5f2e63737620616e6420746865207461626c657320696e206d657461646174612f2e0a0a46726f6d20507974686f6e3a0a20202020696d706f72742072756e70790a202020206466203d2072756e70792e72756e5f7061746828223c6465706f7369743e2f73657475702f5f5f444154415345545f5f5f73657475702e707922295b226c6f6164225d28290a202020206466203d2072756e70792e72756e5f7061746828223c6465706f7369743e2f73657475702f5f5f444154415345545f5f5f73657475702e707922295b226c6f6164225d2863617465676f726963616c733d54727565290a46726f6d2061207368656c6c3a0a20202020707974686f6e2073657475702f5f5f444154415345545f5f5f73657475702e7079205b2d2d726f6f74204449525d205b2d2d736176652d7069636b6c652046494c455d205b2d2d736176652d706172717565742046494c455d0a0a4e656564732070616e64617320616e6420746865207374616e64617264206c696272617279206f6e6c792e204c6162656c7320616e64206f74686572206d657461646174612061726520696e0a64662e61747472735b22646174616465706f736974225d3b2074686520707972656164737461742d7374796c65206e616d65732028636f6c756d6e5f6e616d65735f746f5f6c6162656c732c0a7661726961626c655f76616c75655f6c6162656c732c2076616c75655f6c6162656c732c207661726961626c655f746f5f6c6162656c292061726520616c736f20736574206174207468650a746f70206c6576656c206f662064662e61747472732e204576657279206c6162656c2c2076616c7565206c6162656c2c206e6f74652c20616e642063686172616374657269737469630a636f6d65732066726f6d20746865206d65746164617461207461626c65732c20736f20796f752063616e20656469742074686f7365207461626c657320616e6420726572756e2e0a2222220a0a696d706f7274206373760a696d706f7274206f730a696d706f72742072650a696d706f7274207379730a0a7472793a0a20202020696d706f72742070616e6461732061732070640a65786365707420496d706f72744572726f723a20202320707261676d613a206e6f20636f766572202d20646570656e6473206f6e20746865206d616368696e650a202020207379732e65786974282273657475703a207468697320736372697074206e65"
        h = h + "6564732070616e6461732e20496e7374616c6c20697420776974683a2020707974686f6e202d6d2070697020696e7374616c6c2070616e6461735c6e220a202020202020202020202020202220202020202020286f723a20636f6e646120696e7374616c6c2070616e646173292e205468656e2072756e20746869732066696c6520616761696e2e22290a0a44415441534554203d20225f5f444154415345545f5f220a53504543203d2022312e30220a5f544147203d2072652e636f6d70696c652872225e5c2e5b612d7a5d2422290a5f5441474745445f4e414e203d20307837464638303030303030303030303030202020232061207175696574204e614e3b20746865206c6f77206279746520686f6c6473203120282e612920746f20323620282e7a290a0a0a636c617373205f4d6574612864696374293a0a202020202222224d6574616461746120746861742070616e64617320736861726573206265747765656e206672616d657320696e7374656164206f6620636f7079696e672e0a0a2020202070616e64617320646565702d636f706965732064662e6174747273206f6e20616c6d6f7374206576657279206f7065726174696f6e2e20466f722061207375727665792066696c650a20202020776974682074686f7573616e6473206f66207661726961626c6573207468617420776f756c64206d616b65206561636820636f6c756d6e2061636365737320736c6f772c20736f0a2020202074686573652064696374696f6e6172696573206172652068616e646564206f6e2061732074686579206172652e205468657920646573637269626520746865206465706f7369742c0a202020206e6f74206f6e65206672616d652c20736f2073686172696e67207468656d20697320736166652e205069636b6c696e67207475726e73207468656d20696e746f20706c61696e0a2020202064696374696f6e61726965732e0a202020202222220a0a20202020646566205f5f64656570636f70795f5f2873656c662c206d656d6f293a0a202020202020202072657475726e2073656c660a0a20202020646566205f5f636f70795f5f2873656c66293a0a202020202020202072657475726e2073656c660a0a20202020646566205f5f7265647563655f5f2873656c66293a0a202020202020202072657475726e2028646963742c2028646963742873656c66292c29290a0a0a646566205f6865726528293a0a202020207472793a0a202020202020202072657475726e206f732e706174682e6469726e616d65286f732e706174682e61627370617468285f5f66696c655f5f29290a20202020657863657074204e616d654572726f723a0a20202020202020207265747572"
        h = h + "6e206f732e67657463776428290a0a0a646566205f66696e645f726f6f7428726f6f743d4e6f6e65293a0a20202020646566206f6b2864293a0a202020202020202072657475726e206f732e706174682e657869737473286f732e706174682e6a6f696e28642c20226d65746164617461222c2044415441534554202b20225f7661726961626c65732e6373762229290a0a20202020696620726f6f74206973206e6f74204e6f6e653a0a20202020202020206966206e6f74206f6b28726f6f74293a0a20202020202020202020202072616973652046696c654e6f74466f756e644572726f72282273657475703a206e6f206d657461646174612f25735f7661726961626c65732e63737620756e6465722025732220252028444154415345542c20726f6f7429290a202020202020202072657475726e20726f6f740a20202020666f722063616e6420696e20286f732e706174682e6469726e616d65285f686572652829292c206f732e67657463776428292c206f732e706174682e6469726e616d65286f732e676574637764282929293a0a20202020202020206966206f6b2863616e64293a0a20202020202020202020202072657475726e2063616e640a2020202072616973652046696c654e6f74466f756e644572726f72282273657475703a2063616e6e6f742066696e64206d657461646174612f25735f7661726961626c65732e6373763b207061737320726f6f743d2220252044415441534554290a0a0a646566205f7461626c6528726f6f742c20746162293a0a2020202070617468203d206f732e706174682e6a6f696e28726f6f742c20226d65746164617461222c202225735f25732e6373762220252028444154415345542c2074616229290a2020202077697468206f70656e28706174682c206e65776c696e653d22222c20656e636f64696e673d227574662d3822292061732066683a0a202020202020202072657475726e206c697374286373762e4469637452656164657228666829290a0a0a646566205f76616c75652876293a0a2020202072657475726e2076206966205f5441472e6d6174636828762920656c736520696e742876292069662072652e6d617463682872225e2d3f5c642b24222c20762920656c736520666c6f61742876290a0a0a646566206c6f616428726f6f743d4e6f6e652c2063617465676f726963616c733d46616c7365293a0a2020202022222252657475726e20746865206461746173657420617320612070616e64617320446174614672616d65207769746820697473206d6574616461746120696e2064662e61747472732e2222220a20202020726f6f74203d205f66696e645f726f6f7428726f6f74290a2020202076"
        h = h + "61726961626c6573203d205f7461626c6528726f6f742c20227661726961626c657322290a20202020766c6162656c73203d205f7461626c6528726f6f742c202276616c75656c6162656c7322290a202020206368617273203d205f7461626c6528726f6f742c2022636861727322290a2020202064617461736574203d207b725b226b6579225d3a20725b2276616c7565225d20666f72207220696e205f7461626c6528726f6f742c20226461746173657422297d0a0a202020206474797065732c206e615f76616c756573203d207b7d2c207b7d0a20202020666f72207620696e207661726961626c65733a0a2020202020202020696620765b226b696e64225d203d3d20226e756d657269632220616e6420765b22657874656e6465645f6d697373696e67225d20213d202231223a0a2020202020202020202020206474797065735b765b226e616d65225d5d203d2022666c6f61743634220a2020202020202020202020206e615f76616c7565735b765b226e616d65225d5d203d205b22225d0a2020202020202020656c73653a0a2020202020202020202020206474797065735b765b226e616d65225d5d203d207374720a2020202070617468203d206f732e706174682e6a6f696e28726f6f742c202264617461222c2044415441534554202b20222e63737622290a20202020232070616e646173203320706172736573206576657279206e756d6265722065786163746c792062792064656661756c743b206f6c6465722070616e646173206e656564730a202020202320666c6f61745f707265636973696f6e3d22726f756e645f747269702220746f20646f20736f0a202020206578616374203d207b7d20696620696e742870642e5f5f76657273696f6e5f5f2e73706c697428222e22295b305d29203e3d203320656c7365207b22666c6f61745f707265636973696f6e223a2022726f756e645f74726970227d0a202020206466203d2070642e726561645f63737628706174682c2064747970653d6474797065732c206b6565705f64656661756c745f6e613d46616c73652c206e615f76616c7565733d6e615f76616c7565732c0a202020202020202020202020202020202020202020656e636f64696e673d227574662d38222c207365703d222c222c2071756f7465636861723d2722272c20646f75626c6571756f74653d547275652c202a2a6578616374290a2020202069662064662e73686170655b315d20213d206c656e287661726961626c6573293a0a202020202020202072616973652056616c75654572726f72282273657475703a2025732068617320256420636f6c756d6e732062757420746865207661726961626c6573207461626c65206c6973"
        h = h + "7473202564220a20202020202020202020202020202020202020202020202020252028706174682c2064662e73686170655b315d2c206c656e287661726961626c65732929290a2020202064662e636f6c756d6e73203d205b765b226e616d65225d20666f72207620696e207661726961626c65735d0a0a2020202073657473203d207b7d0a20202020666f72207220696e20766c6162656c733a0a2020202020202020736574732e73657464656661756c7428725b22736574225d2c207b7d295b5f76616c756528725b2276616c7565225d295d203d20725b226c6162656c225d0a0a2020202062795f766172203d207b7d0a20202020666f72207220696e2063686172733a0a202020202020202062795f7661722e73657464656661756c7428725b227661726961626c65225d2c205b5d292e617070656e642872290a0a202020206465662073706c69745f636861727328766172293a0a20202020202020206e6f7465732c206f74686572203d205b5d2c207b7d0a2020202020202020666f72207220696e2062795f7661722e676574287661722c205b5d293a0a2020202020202020202020206d203d2072652e6d617463682872225e6e6f7465285c642b2924222c20725b2263686172225d290a2020202020202020202020206966206d3a0a202020202020202020202020202020206966206d2e67726f757028312920213d202230223a0a20202020202020202020202020202020202020206e6f7465732e617070656e642828696e74286d2e67726f7570283129292c20725b2274657874225d29290a202020202020202020202020656c696620725b2263686172225d206e6f7420696e202822646174616465706f7369745f6c6162656c222c2022646174616465706f7369745f6e616d6522293a0a202020202020202020202020202020206f746865725b725b2263686172225d5d203d20725b2274657874225d0a202020202020202072657475726e205b7420666f72205f2c207420696e20736f72746564286e6f746573295d2c206f746865720a0a202020207163686172203d20646174617365742e67657428227175657374696f6e5f63686172222c202222290a202020206d657461203d205f4d657461287b2264617461736574223a20444154415345542c202273706563223a20535045432c2022726f6f74223a206f732e706174682e6162737061746828726f6f74292c0a2020202020202020202020202020202020202266696c655f6c6162656c223a20646174617365742e67657428226c6162656c222c202222292c2022736f727465646279223a20646174617365742e6765742822736f727465646279222c202222292c0a20202020202020202020202020"
        h = h + "202020202022636f6c756d6e5f6c6162656c73223a205f4d65746128292c20227661726961626c655f76616c75655f6c6162656c73223a205f4d65746128292c202276616c75655f6c6162656c73223a205f4d6574612873657473292c0a202020202020202020202020202020202020227661726961626c655f746f5f6c6162656c223a205f4d65746128292c2022666f726d617473223a207b7d2c202273746174615f7479706573223a207b7d2c20226e6f746573223a207b7d2c0a202020202020202020202020202020202020226368617273223a207b7d2c20227175657374696f6e73223a207b7d2c2022657874656e6465645f6d697373696e67223a207b7d2c20227661726961626c6573223a207661726961626c65732c0a20202020202020202020202020202020202022636861725f726f7773223a2063686172732c2022646174617365745f7461626c65223a20646174617365747d290a0a20202020666f72207620696e207661726961626c65733a0a20202020202020206e616d652c206b696e64203d20765b226e616d65225d2c20765b226b696e64225d0a2020202020202020636f6c203d2064665b6e616d655d0a20202020202020206966206b696e6420213d2022737472696e672220616e64206e6f742070642e6170692e74797065732e69735f6e756d657269635f647479706528636f6c293a0a20202020202020202020202073203d20636f6c2e61737479706528737472290a20202020202020202020202074616773203d20732e7374722e6d617463682872225e5c2e5b612d7a5d2422290a202020202020202020202020696620746167732e616e7928293a0a20202020202020202020202020202020657874203d207b7d0a20202020202020202020202020202020666f72206964782c20746f6b20696e20735b746167735d2e6974656d7328293a0a20202020202020202020202020202020202020206578742e73657464656661756c7428746f6b5b315d2c205b5d292e617070656e6428696e742869647829290a202020202020202020202020202020206d6574615b22657874656e6465645f6d697373696e67225d5b6e616d655d203d206578740a20202020202020202020202073203d20732e7768657265287e746167732c202222290a2020202020202020202020206966206b696e64203d3d20226e756d65726963223a0a202020202020202020202020202020206e756d203d2070642e746f5f6e756d6572696328732e7768657265287320213d2022222c204e6f6e65292c206572726f72733d22636f6572636522290a20202020202020202020202020202020626164203d206e756d2e69736e612829202620287320213d202222290a2020"
        h = h + "20202020202020202020202020206966206261642e616e7928293a0a202020202020202020202020202020202020202072616973652056616c75654572726f72282273657475703a20257320686173206e6f6e2d6e756d657269632076616c7565732c2066697273743a20257222202520286e616d652c20735b6261645d2e696c6f635b305d29290a2020202020202020202020202020202064665b6e616d655d203d206e756d2e6173747970652822666c6f6174363422290a202020202020202020202020656c6966206b696e64203d3d202264617465223a0a2020202020202020202020202020202064665b6e616d655d203d2070642e746f5f6461746574696d6528732e7768657265287320213d2022222c204e6f6e65292c20666f726d61743d2225592d256d2d2564222c206572726f72733d22726169736522290a202020202020202020202020656c6966206b696e64203d3d20226461746574696d65223a0a2020202020202020202020202020202064665b6e616d655d203d2070642e746f5f6461746574696d6528732e7768657265287320213d2022222c204e6f6e65292c20666f726d61743d2225592d256d2d25642025483a254d3a25532e2566222c206572726f72733d22726169736522290a20202020202020206966206b696e64203d3d20226e756d657269632220616e6420765b2273746174615f74797065225d203d3d2022666c6f6174223a0a2020202020202020202020202320537461746120666c6f6174732061726520666c6f617433323b2074686520637376207465787420726f756e6473206261636b20746f207468652073616d6520666c6f617433320a20202020202020202020202064665b6e616d655d203d2064665b6e616d655d2e6173747970652822666c6f6174333222292e6173747970652822666c6f6174363422290a20202020202020206966206b696e64203d3d20226e756d657269632220616e64206e616d6520696e206d6574615b22657874656e6465645f6d697373696e67225d3a0a20202020202020202020202023206b656570206561636820657874656e646564206d697373696e6720636f646520282e6120746f202e7a2920696e7369646520697473204e614e2c206173205227730a2020202020202020202020202320686176656e20646f65732c20736f2074686520636f646520666f6c6c6f77732074686520726f77207468726f7567682066696c7465727320616e6420736f7274730a202020202020202020202020617272203d2064665b6e616d655d2e746f5f6e756d70792864747970653d22666c6f61743634222c20636f70793d54727565290a20202020202020202020202062697473203d206172722e7669"
        h = h + "6577282275696e74363422290a202020202020202020202020666f72206c65747465722c2069647820696e206d6574615b22657874656e6465645f6d697373696e67225d5b6e616d655d2e6974656d7328293a0a20202020202020202020202020202020626974735b6964785d203d205f5441474745445f4e414e202b20286f7264286c657474657229202d203936290a20202020202020202020202064665b6e616d655d203d206172720a2020202020202020696620765b226c6162656c225d3a0a2020202020202020202020206d6574615b22636f6c756d6e5f6c6162656c73225d5b6e616d655d203d20765b226c6162656c225d0a20202020202020206d6574615b22666f726d617473225d5b6e616d655d203d20765b22666f726d6174225d0a20202020202020206d6574615b2273746174615f7479706573225d5b6e616d655d203d20765b2273746174615f74797065225d0a2020202020202020696620765b2276616c75655f6c6162656c73225d3a0a2020202020202020202020206d6574615b227661726961626c655f746f5f6c6162656c225d5b6e616d655d203d20765b2276616c75655f6c6162656c73225d0a2020202020202020202020206d6574615b227661726961626c655f76616c75655f6c6162656c73225d5b6e616d655d203d206469637428736574732e67657428765b2276616c75655f6c6162656c73225d2c207b7d29290a20202020202020206e6f7465732c206f74686572203d2073706c69745f636861727328765b2273746174615f6e616d65225d290a20202020202020206966206e6f7465733a0a2020202020202020202020206d6574615b226e6f746573225d5b6e616d655d203d206e6f7465730a20202020202020206966206f746865723a0a2020202020202020202020206d6574615b226368617273225d5b6e616d655d203d206f746865720a202020202020202020202020696620716368617220616e6420716368617220696e206f746865723a0a202020202020202020202020202020206d6574615b227175657374696f6e73225d5b6e616d655d203d206f746865725b71636861725d0a202020202020202069662063617465676f726963616c7320616e6420765b2276616c75655f6c6162656c73225d20616e64206b696e64203d3d20226e756d65726963223a0a2020202020202020202020206c6162656c73203d207b6b3a207420666f72206b2c207420696e20736574732e67657428765b2276616c75655f6c6162656c73225d2c207b7d292e6974656d732829206966206e6f74206973696e7374616e6365286b2c20737472297d0a0a202020202020202020202020646566206c616228632c206c6162656c733d6c616265"
        h = h + "6c73293a0a2020202020202020202020202020202069662070642e69736e612863293a0a202020202020202020202020202020202020202072657475726e204e6f6e650a20202020202020202020202020202020696620666c6f61742863292e69735f696e7465676572282920616e6420696e7428632920696e206c6162656c733a0a202020202020202020202020202020202020202072657475726e206c6162656c735b696e742863295d0a2020202020202020202020202020202072657475726e2022256722202520630a0a2020202020202020202020206d6170706564203d2064665b6e616d655d2e6d6170286c6162290a20202020202020202020202063617473203d206c69737428646963742e66726f6d6b657973286c697374286c6162656c732e76616c756573282929202b206c697374286d61707065642e64726f706e6128292e756e6971756528292929290a20202020202020202020202064665b6e616d655d203d2070642e43617465676f726963616c286d61707065642c2063617465676f726965733d63617473290a0a202020206e6f7465732c206f74686572203d2073706c69745f636861727328225f64746122290a202020206d6574615b226e6f746573225d5b225f647461225d203d206e6f7465730a202020206d6574615b226368617273225d5b225f647461225d203d206f746865720a0a2020202064662e61747472735b22646174616465706f736974225d203d206d6574610a2020202064662e61747472735b22636f6c756d6e5f6e616d65735f746f5f6c6162656c73225d203d206d6574615b22636f6c756d6e5f6c6162656c73225d0a2020202064662e61747472735b227661726961626c655f76616c75655f6c6162656c73225d203d206d6574615b227661726961626c655f76616c75655f6c6162656c73225d0a2020202064662e61747472735b2276616c75655f6c6162656c73225d203d206d6574615b2276616c75655f6c6162656c73225d0a2020202064662e61747472735b227661726961626c655f746f5f6c6162656c225d203d206d6574615b227661726961626c655f746f5f6c6162656c225d0a2020202064662e61747472735b2266696c655f6c6162656c225d203d206d6574615b2266696c655f6c6162656c225d0a202020207072696e74282273657475703a206275696c7420257320282564206f62732c20256420766172732c202564207661726961626c65206c6162656c732c2025642076616c7565206c6162656c732c2025642063686172616374657269737469637329220a20202020202020202020252028444154415345542c2064662e73686170655b305d2c2064662e73686170655b315d2c206c656e286d6574"
        h = h + "615b22636f6c756d6e5f6c6162656c73225d292c206c656e28766c6162656c73292c206c656e28636861727329292c0a2020202020202020202066696c653d7379732e737464657272290a2020202072657475726e2064660a0a0a646566205f6d61696e2861726776293a0a202020206465662061726728666c6167293a0a202020202020202072657475726e20617267765b617267762e696e64657828666c616729202b20315d20696620666c616720696e206172677620616e6420617267762e696e64657828666c616729202b2031203c206c656e28617267762920656c7365204e6f6e650a0a202020206466203d206c6f616428726f6f743d61726728222d2d726f6f742229290a202020206f7574203d2061726728222d2d736176652d7069636b6c6522290a202020206966206f75743a0a202020202020202064662e746f5f7069636b6c65286f7574290a202020206f7574203d2061726728222d2d736176652d7061727175657422290a202020206966206f75743a0a202020202020202064662e746f5f70617271756574286f7574290a2020202072657475726e2064660a0a0a6966205f5f6e616d655f5f203d3d20225f5f6d61696e5f5f223a0a202020205f6d61696e287379732e617267765b313a5d290a"
    }
    return(_ddp_unhex(h))
}

string scalar _ddp_unhex(string scalar h)
{
    real rowvector b, idx
    if (h == "") return("")
    b = ascii(h)
    b = b :- 48 :- 39 :* (b :>= 97)
    idx = (1..(cols(b) / 2)) :* 2
    return(char(16 :* b[idx :- 1] :+ b[idx]))
}
end
* ===== END EMBEDDED TEMPLATES =====
