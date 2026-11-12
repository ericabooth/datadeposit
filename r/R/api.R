#' Write an archive-ready data deposit
#'
#' Writes a folder with the data (csv plus native copies), a codebook
#' (Markdown, Excel, DDI 2.5 XML, Frictionless datapackage.json), the
#' metadata tables, and setup scripts that rebuild the labelled data from the
#' csv in Stata, R, and Python. The same command exists in Stata
#' (\code{datadeposit}) and Python (\code{datadeposit()}), and all three
#' write the same folder.
#'
#' @param data a data frame, a named list of data frames, or file paths
#'   (\code{.dta} files are read with every label, note, and characteristic).
#' @param to the deposit folder; defaults to \code{<name>_deposit} in the working directory.
#' @param name dataset name (the file stem used inside the deposit).
#' @param files,folder,pattern deposit several files, or every file in a folder.
#' @param formats data files to write, from \code{csv dta rds xlsx sav}; default
#'   \code{c("csv", "dta", "rds")}.
#' @param lean keep the native file (\code{.rds}) plus the csv; the setup scripts
#'   cover the other languages.
#' @param nodata metadata, codebook, and setup scripts only.
#' @param replace overwrite an earlier deposit in \code{to}.
#' @param max_size_gb,allow_large,on_large the size check: stop when any data file
#'   would exceed \code{max_size_gb} unless \code{allow_large = TRUE}, or switch to
#'   lean with \code{on_large = "lean"}.
#' @param title,authors,description,license,version,changes deposit documentation.
#' @param include extra files (questionnaires, do-files) copied into \code{docs/}.
#' @param question name of the characteristic that holds item text (found
#'   automatically when it is \code{question}, \code{item}, \code{qtext}, and so on).
#' @param stats write summary statistics and frequencies.
#' @param verify rebuild the data from the csv afterwards and compare.
#' @param hash write sha256 hashes in MANIFEST.json.
#' @param quiet suppress the receipt.
#' @return a list with the deposit path, datasets, formats, profile, and check result.
#' @examples
#' \dontrun{
#' datadeposit("survey.dta", to = "survey_deposit", title = "Spring survey")
#' datadeposit(mtcars, to = "cars_deposit", lean = TRUE)
#' }
#' @export
datadeposit <- function(data = NULL, to = NULL, name = NULL, files = NULL, folder = NULL, pattern = "*.dta",
                        formats = NULL, lean = FALSE, nodata = FALSE, replace = FALSE, max_size_gb = 5,
                        allow_large = FALSE, on_large = c("stop", "lean"), title = "", authors = "",
                        description = "", license = "", version = NULL, changes = "", include = character(0),
                        question = NULL, stats = TRUE, verify = TRUE, hash = TRUE, quiet = FALSE) {
  on_large <- match.arg(on_large)
  if (lean && nodata) stop("lean and nodata cannot be combined", call. = FALSE)
  authors <- paste(authors, collapse = "; ")
  if (!is.null(version)) version <- as.character(version)
  say <- function(...) if (!quiet) message(...)

  # ---- datasets
  skipped <- character(0)
  if (!is.null(folder)) {
    found <- dd_bsort(Sys.glob(file.path(folder, pattern)))   # byte order, as Stata and Python sort
    found <- found[!dir.exists(found)]
    files <- character(0)
    for (p in found) {
      sn <- dd_sniff(p)
      if (sn$is_data) files <- c(files, p) else skipped <- c(skipped, paste0(basename(p), " (", sn$why, ")"))
    }
    if (!length(files)) stop("no data files match ", pattern, " in ", folder,
                             if (length(skipped)) paste0("; skipped: ", paste(skipped, collapse = "; ")), call. = FALSE)
  }
  if (is.null(files) && is.character(data)) files <- data
  items <- list()
  from_files <- !is.null(files)
  if (from_files) {
    for (p in files) {
      if (!file.exists(p) && file.exists(paste0(p, ".dta"))) p <- paste0(p, ".dta")
      if (!file.exists(p)) stop("file ", p, " not found", call. = FALSE)
      items[[length(items) + 1L]] <- list(stem = if (!is.null(name) && length(files) == 1) dd_clean(name) else dd_stem(p), src = p)
    }
  } else if (is.data.frame(data)) {
    nm <- if (!is.null(name)) name else deparse(substitute(data))
    items[[1]] <- list(stem = dd_clean(if (grepl("^[A-Za-z0-9_.-]+$", nm)) nm else "data"), src = data)
  } else if (is.list(data) && length(data)) {
    for (k in names(data)) items[[length(items) + 1L]] <- list(stem = dd_clean(k), src = data[[k]])
  } else stop("give a data frame, a named list of data frames, or file paths", call. = FALSE)
  # a data frame loaded with deposit_use: name, version, and folder follow the parent
  prov <- ""
  if (!from_files && length(items) == 1 && !is.null(attr(items[[1]]$src, "datadeposit")$provenance)) {
    prov <- attr(items[[1]]$src, "datadeposit")$provenance
    pp <- c(strsplit(prov, "|", fixed = TRUE)[[1]], "", "", "", "")[1:4]
    if (is.null(name) && nzchar(pp[4])) items[[1]]$stem <- pp[4]
    if (is.null(version) && grepl("^[0-9]+$", pp[2])) version <- as.character(as.integer(pp[2]) + 1L)
  }
  if (is.null(version)) version <- "1"
  stems <- vapply(items, `[[`, "", "stem")
  renamed <- character(0)
  seen <- character(0)
  for (k in seq_along(items)) {
    st <- items[[k]]$stem
    if (st %in% seen) {
      i <- 2L
      while (paste0(st, "_", i) %in% c(seen, stems)) i <- i + 1L
      new <- paste0(st, "_", i)
      renamed <- c(renamed, sprintf("%s would also be named %s; it is named %s in the deposit",
                                    if (is.character(items[[k]]$src)) basename(items[[k]]$src) else st, st, new))
      items[[k]]$stem <- new
    }
    seen <- c(seen, items[[k]]$stem)
  }
  stems <- vapply(items, `[[`, "", "stem")
  if (is.null(to)) {
    if (length(items) > 1) stop("several datasets: say where the deposit goes with to =", call. = FALSE)
    # Without to, the deposit goes to the working directory, not beside the
    # source file (that folder may be a data folder other code reads). A new
    # version of a loaded deposit goes beside its parent when the parent's
    # folder is still there.
    base <- "."
    if (nzchar(prov) && dir.exists(strsplit(prov, "|", fixed = TRUE)[[1]][1])) {
      base <- dirname(strsplit(prov, "|", fixed = TRUE)[[1]][1])
    }
    to <- file.path(base, paste0(stems[1], if (version == "1") "_deposit" else paste0("_deposit_v", version)))
  }

  # ---- profile
  if (!is.null(formats)) {
    if (lean || nodata) stop("formats cannot be combined with lean or nodata", call. = FALSE)
    fmts <- unique(tolower(formats))
    bad <- setdiff(fmts, c("csv", "dta", "rds", "xlsx", "sav"))
    if (length(bad)) stop("formats: ", bad[1], " is not one of csv dta rds xlsx sav", call. = FALSE)
    if (!"csv" %in% fmts) stop("formats must include csv: the csv is the portable copy every setup script reads", call. = FALSE)
    profile <- "custom"
  } else if (nodata) { profile <- "nodata"; fmts <- character(0) }
  else if (lean) { profile <- "lean"; fmts <- c("csv", "rds") }
  else { profile <- "full"; fmts <- c("csv", "dta", "rds") }

  # ---- load and size check
  tabs <- lapply(items, function(it) {
    t <- if (is.character(it$src)) dd_read_any(it$src, it$stem) else dd_from_frame(it$src, it$stem)
    if (!is.null(question)) t$question_char <- question
    for (n in t$notes) say("datadeposit: note: ", n)
    t
  })
  for (sk in skipped) say("datadeposit: skipped ", sk)
  for (rn in renamed) say("datadeposit: note: ", rn)
  largest <- 0; largest_file <- ""; total_full <- 0; total_lean <- 0
  for (t in tabs) {
    est <- dd_estimate(t)
    total_full <- total_full + est[["csv"]] + 2 * est[["dta"]]
    total_lean <- total_lean + est[["csv"]] + est[["dta"]]
    for (f in fmts) {
      e <- if (f == "csv") est[["csv"]] else if (f == "xlsx") 1.3 * est[["csv"]] else est[["dta"]]
      if (e > largest) { largest <- e; largest_file <- paste0("data/", t$name, ".", f) }
    }
  }
  size_override <- "none"
  if (largest > max_size_gb * 1e9 && !profile %in% c("lean", "nodata")) {
    if (allow_large) {
      size_override <- "allowlarge"
      say("datadeposit: note: ", largest_file, " will be about ", dd_size(largest), " (allow_large)")
    } else if (on_large == "lean") {
      size_override <- "onlarge_lean"; profile <- "lean"; fmts <- c("csv", "rds")
      say("datadeposit: ", largest_file, " would be about ", dd_size(largest), ", over the ", max_size_gb,
          " GB limit; on_large = \"lean\" switched to the lean profile (.rds + .csv + setup scripts)")
    } else {
      stop(largest_file, " would be about ", dd_size(largest), ", over the ", max_size_gb, " GB limit (max_size_gb).\n",
           "  Nothing was written. Choose one:\n",
           "    lean = TRUE         keep the .rds plus one .csv and the setup scripts (about ", dd_size(total_lean), " in all)\n",
           "    nodata = TRUE       codebook, metadata, and setup scripts only (no data copies)\n",
           "    allow_large = TRUE  write every format anyway (about ", dd_size(total_full), " in all)\n",
           "  Or raise max_size_gb, or pass on_large = \"lean\" so a deposit at the end of a script\n",
           "  switches to lean by itself when the data grow.", call. = FALSE)
    }
  } else if (profile == "lean" && largest > max_size_gb * 1e9) size_override <- "lean"

  # ---- write
  dd_prepare(to, replace, length(include) > 0)
  engines <- list()
  for (t in tabs) engines <- dd_one(to, t, fmts, stats, engines, say)
  for (f in include) file.copy(f, file.path(to, "docs", basename(f)), overwrite = TRUE)
  info <- list(title = title, description = description, authors = authors, license = license, version = version,
               changes = changes, derived = tabs[[1]]$provenance, profile = profile, formats = fmts,
               package_version = PACKAGE_VERSION, software = paste("R", getRversion()), engine = "R",
               max_gb = max_size_gb, largest = largest, size_override = size_override)
  dd_write_datapackage(to, stems, info)
  dd_write_readme(to, stems, info)
  mhash <- dd_write_manifest(to, stems, info, engines, hash)

  verified <- "skipped"
  if (verify && profile == "nodata") verified <- "not applicable (no data files)"
  else if (verify && largest > 1e9) say("datadeposit: round-trip check skipped for data over 1 GB; run deposit_verify(\"", to, "\")")
  else if (verify) verified <- if (all(vapply(stems, function(s) dd_roundtrip(to, s, say), logical(1)))) "passed" else "FAILED"

  say(strrep("-", 72))
  say("datadeposit wrote ", normalizePath(to))
  say("  profile ", profile, ", datasets: ", paste(stems, collapse = " "))
  for (t in tabs) say("  ", t$name, ": ", t$nobs, " obs, ", length(t$columns), " vars")
  if (length(fmts)) say("  data formats: ", paste(fmts, collapse = " "))
  if (!requireNamespace("writexl", quietly = TRUE)) {
    say("  note: no codebook .xlsx was written because the writexl package is not installed;\n",
        "    install it with  install.packages(\"writexl\")  (the csv and Markdown codebook are complete)")
  }
  if (!requireNamespace("haven", quietly = TRUE)) {
    say("  note: haven is not installed, so labelled values load as plain numbers with a labels attribute;\n",
        "    install.packages(\"haven\") gives haven_labelled vectors and tagged missing codes")
  }
  say("  R round trip (csv + setup.R vs. the data): ", verified)
  say(strrep("-", 72))
  if (verified == "FAILED") stop("the round-trip check found differences; see the messages above", call. = FALSE)
  invisible(list(path = normalizePath(to), datasets = stems, formats = fmts, profile = profile,
                 verified = verified, manifest_sha256 = mhash, largest_gb = largest / 1e9))
}

#' Metadata, codebook, and setup scripts only
#' @param ... passed to \code{datadeposit()}.
#' @export
deposit_codebook <- function(...) datadeposit(..., nodata = TRUE)

dd_size <- function(b) {
  if (b >= 1e9) return(sprintf("%.1f GB", b / 1e9))
  if (b >= 1e6) return(sprintf("%.1f MB", b / 1e6))
  sprintf("%.0f KB", max(1, round(b / 1e3)))
}

dd_estimate <- function(t) {
  w <- 0
  for (c in t$columns) {
    st <- c$stata_type
    w <- w + if (st == "strL") 8 + if (t$nobs) mean(nchar(utils::head(c$values, 1000), type = "bytes")) else 0
    else if (startsWith(st, "str")) as.numeric(substr(st, 4, 9))
    else c(byte = 1, int = 2, long = 4, float = 4, double = 8)[[st]]
  }
  e_dta <- t$nobs * w + 2000 * length(t$columns) + 4000
  n <- min(t$nobs, 1000)
  if (!n) return(c(dta = e_dta, csv = 0))
  s <- t
  s$nobs <- n
  s$columns <- lapply(t$columns, function(c) { c$values <- c$values[seq_len(n)]; if (!is.null(c$ext)) c$ext <- c$ext[seq_len(n)]; c })
  tf <- tempfile(fileext = ".csv")
  on.exit(unlink(tf))
  dd_write_data_csv(tf, s)
  c(dta = e_dta, csv = file.size(tf) / n * t$nobs)
}

dd_check_finished <- function(path) {
  if (!dd_is_deposit(path)) stop(path, " is not a datadeposit folder (no MANIFEST.json)", call. = FALSE)
  if (identical(jsonlite::fromJSON(file.path(path, "MANIFEST.json"))$status, "incomplete")) {
    stop("the deposit in ", path, " did not finish; run datadeposit() again with replace = TRUE", call. = FALSE)
  }
}

dd_is_deposit <- function(folder) {
  m <- file.path(folder, "MANIFEST.json")
  file.exists(m) && !is.null(tryCatch(jsonlite::fromJSON(m)$datadeposit, error = function(e) NULL))
}

dd_prepare <- function(to, replace, docs) {
  if (dir.exists(to) && length(list.files(to, all.files = TRUE, no.. = TRUE))) {
    if (!replace) stop("folder ", to, " already exists; pass replace = TRUE to overwrite an earlier deposit", call. = FALSE)
    if (!dd_is_deposit(to)) stop(to, " is not a datadeposit folder (no MANIFEST.json written by datadeposit); ",
                                 "replace only overwrites earlier deposits, so nothing was deleted", call. = FALSE)
    m <- jsonlite::fromJSON(file.path(to, "MANIFEST.json"))
    if (identical(m$status, "incomplete")) {
      message("datadeposit: an earlier deposit in this folder did not finish; replacing it")
      for (sub in c("data", "metadata", "codebook", "setup", "docs")) {
        d <- file.path(to, sub)
        if (dir.exists(d)) unlink(file.path(d, list.files(d)))
      }
      unlink(file.path(to, c("README.md", "datapackage.json")))
    }
    if (is.data.frame(m$files)) for (p in m$files$path) { f <- file.path(to, p); if (file.exists(f)) unlink(f) }
    unlink(file.path(to, "MANIFEST.json"))
    for (sub in c("data", "metadata", "codebook", "setup", "docs")) {
      d <- file.path(to, sub)
      if (dir.exists(d) && !length(list.files(d, all.files = TRUE, no.. = TRUE))) unlink(d, recursive = TRUE)
    }
  }
  if (file.exists(to) && !dir.exists(to)) stop(to, " is a file, not a folder; choose another place for the deposit", call. = FALSE)
  for (sub in c("data", "metadata", "codebook", "setup", if (docs) "docs")) dir.create(file.path(to, sub), recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(file.path(to, "data")) || file.access(to, 2) != 0) {
    stop("cannot write to ", to, "; check that the folder exists and that you may write there", call. = FALSE)
  }
  # mark the folder as an unfinished deposit until MANIFEST.json is written
  dd_spit(file.path(to, "MANIFEST.json"), '{"datadeposit": "1.0", "status": "incomplete", "files": []}\n')
}

dd_write_templates <- function(root, ds) {
  for (lang in c(do = "setup.do", R = "setup.R", py = "setup.py")) {
    src <- system.file("templates", lang, package = "datadeposit")
    txt <- readChar(src, file.size(src), useBytes = TRUE)
    Encoding(txt) <- "UTF-8"
    txt <- gsub("__DATASET__", ds, txt, fixed = TRUE)
    ext <- sub("^setup\\.", "", lang)
    dd_spit(file.path(root, "setup", paste0(ds, "_setup.", ext)), txt)
  }
}

dd_run_setup <- function(root, ds) {
  op <- options(datadeposit.root = root, datadeposit.assign = FALSE)
  on.exit(options(op))
  env <- new.env(parent = globalenv())
  withCallingHandlers(
    source(file.path(root, "setup", paste0(ds, "_setup.R")), local = env)$value,
    message = function(m) invokeRestart("muffleMessage"))
}

dd_one <- function(root, t, fmts, stats, engines, say) {
  dd_write_metadata(root, t)
  if (stats) dd_write_stats(root, t)
  dd_write_templates(root, t$name)
  for (f in fmts) {
    rel <- paste0("data/", t$name, ".", f)
    if (f == "csv") dd_write_data_csv(file.path(root, rel), t)
    else if (f == "dta") dd_write_dta(file.path(root, rel), t)
  }
  if (any(c("rds", "sav", "xlsx") %in% fmts)) {
    d <- dd_run_setup(root, t$name)
    if ("rds" %in% fmts) saveRDS(d, file.path(root, "data", paste0(t$name, ".rds")))
    if ("sav" %in% fmts) {
      if (requireNamespace("haven", quietly = TRUE)) {
        haven::write_sav(d, file.path(root, "data", paste0(t$name, ".sav")))
        engines[[paste0("data/", t$name, ".sav")]] <- "haven"
      } else say("datadeposit: note: no .sav copy (needs haven)")
    }
    if ("xlsx" %in% fmts) {
      if (requireNamespace("writexl", quietly = TRUE) && t$nobs <= 1048575) {
        codes <- as.data.frame(lapply(d, function(x) { if (inherits(x, "haven_labelled")) x <- as.double(unclass(x)); attributes(x) <- attributes(x)[intersect(names(attributes(x)), c("class", "tzone", "levels"))]; x }), check.names = FALSE)
        labs <- as.data.frame(lapply(d, function(x) {
          l <- attr(x, "labels", exact = TRUE)
          v <- if (inherits(x, "haven_labelled")) as.double(unclass(x)) else x
          attributes(v) <- attributes(v)[intersect(names(attributes(v)), c("class", "tzone"))]
          if (!is.null(l) && is.numeric(v)) { m <- names(l)[match(v, unclass(l))]; ifelse(is.na(m), as.character(v), m) } else v
        }), check.names = FALSE)
        writexl::write_xlsx(list(codes = codes, labels = labs), file.path(root, "data", paste0(t$name, ".xlsx")))
        engines[[paste0("data/", t$name, ".xlsx")]] <- "writexl"
      } else say("datadeposit: note: no .xlsx copy (needs writexl, and at most 1,048,575 rows)")
    }
  }
  dd_write_codebook_md(root, t$name)
  dd_write_ddi(root, t$name)
  if (requireNamespace("writexl", quietly = TRUE)) {
    sheets <- list()
    for (tab in c("variables", "valuelabels", "chars", "dataset", "summary", "frequencies")) {
      p <- dd_meta_path(root, t$name, tab)
      if (!file.exists(p)) next
      x <- dd_read_table(p)
      x[] <- lapply(x, function(v) ifelse(nchar(v) > 32000, paste0(substr(v, 1, 32000),
                    " [cut for Excel; full text in metadata/", t$name, "_", tab, ".csv]"), v))
      sheets[[tab]] <- x
    }
    writexl::write_xlsx(sheets, file.path(root, "codebook", paste0(t$name, "_codebook.xlsx")))
    engines[[paste0("codebook/", t$name, "_codebook.xlsx")]] <- "writexl"
  }
  engines
}

dd_stems <- function(root) {
  f <- list.files(file.path(root, "metadata"), pattern = "_variables\\.csv$")
  dd_bsort(sub("_variables\\.csv$", "", f))
}

#' Load a dataset from a deposit
#'
#' Rebuilds the data from the deposit's csv with its own setup script, so
#' every label, value label, note, and characteristic is attached. The data
#' frame remembers which deposit it came from; a new deposit made from it
#' records that deposit as its parent.
#'
#' @param path the deposit folder.
#' @param name dataset name when the deposit holds several.
#' @param haven use haven_labelled vectors and tagged NAs (when haven is installed).
#' @return a data frame.
#' @export
deposit_use <- function(path, name = NULL, haven = TRUE) {
  dd_check_finished(path)
  stems <- dd_stems(path)
  if (is.null(name)) {
    if (length(stems) > 1) stop("this deposit holds several datasets (", paste(stems, collapse = " "), "); pick one with name =", call. = FALSE)
    name <- stems[1]
  } else if (!name %in% stems) stop("dataset ", name, " is not in this deposit", call. = FALSE)
  op <- options(datadeposit.haven = haven)
  on.exit(options(op))
  d <- dd_run_setup(path, name)
  m <- jsonlite::fromJSON(file.path(path, "MANIFEST.json"))
  a <- attr(d, "datadeposit")
  a$provenance <- paste(normalizePath(path), m$version, dd_sha256(file.path(path, "MANIFEST.json")), name, sep = "|")
  attr(d, "datadeposit") <- a
  d
}

dd_roundtrip <- function(root, ds, say = message) {
  if (!file.exists(file.path(root, "data", paste0(ds, ".csv")))) return(TRUE)
  ok <- TRUE
  dd <- dd_kv(root, ds)
  d <- dd_run_setup(root, ds)
  t <- dd_from_frame(d, ds, dd[["source_file"]])
  t$question_char <- dd[["question_char"]]
  td <- tempfile("ddrt")
  dir.create(file.path(td, "metadata"), recursive = TRUE)
  on.exit(unlink(td, recursive = TRUE))
  dd_write_metadata(td, t)
  for (tab in c("variables", "valuelabels", "chars", "dataset")) {
    a <- dd_meta_path(root, ds, tab); b <- dd_meta_path(td, ds, tab)
    if (!identical(readBin(a, "raw", file.size(a)), readBin(b, "raw", file.size(b)))) {
      say("round trip: ", ds, "_", tab, ".csv rebuilt from the csv differs from the deposit")
      ok <- FALSE
    }
  }
  p <- file.path(root, "data", paste0(ds, ".dta"))
  if (file.exists(p)) {
    ref <- dd_from_dta(p, ds)
    for (i in seq_along(t$columns)) {
      a <- t$columns[[i]]; b <- ref$columns[[i]]
      same <- identical(as.vector(a$values), as.vector(b$values)) ||
        (is.numeric(a$values) && isTRUE(all(is.na(a$values) == is.na(b$values))) &&
           isTRUE(all(a$values[!is.na(a$values)] == b$values[!is.na(b$values)])))
      ea <- if (is.null(a$ext)) integer(t$nobs) else a$ext
      eb <- if (is.null(b$ext)) integer(t$nobs) else b$ext
      if (!same || !identical(as.integer(ea), as.integer(eb))) {
        say("round trip: values of ", a$name, " rebuilt from the csv differ from data/", ds, ".dta")
        ok <- FALSE
      }
    }
  }
  ok
}

#' Check a deposit
#'
#' Confirms that every file still matches MANIFEST.json (size and sha256),
#' and rebuilds each dataset from its csv to compare with the deposit's
#' metadata and its .dta.
#'
#' @param path the deposit folder.
#' @param hash check sha256 hashes as well as sizes.
#' @param quiet suppress messages.
#' @return a list with \code{ok}, \code{files_bad}, and \code{roundtrip_ok}.
#' @export
deposit_verify <- function(path, hash = TRUE, quiet = FALSE) {
  say <- function(...) if (!quiet) message(...)
  dd_check_finished(path)
  m <- jsonlite::fromJSON(file.path(path, "MANIFEST.json"))
  bad <- 0L
  f <- m$files
  for (i in seq_len(nrow(f))) {
    p <- file.path(path, f$path[i])
    if (!file.exists(p)) { say("missing: ", f$path[i]); bad <- bad + 1L }
    else if (file.size(p) != f$bytes[i]) { say("size changed: ", f$path[i]); bad <- bad + 1L }
    else if (hash && nzchar(f$sha256[i]) && dd_sha256(p) != f$sha256[i]) { say("content changed: ", f$path[i]); bad <- bad + 1L }
  }
  say("files: ", nrow(f), " checked, ", bad, " problems")
  rt <- TRUE
  for (ds in dd_stems(path)) {
    ok <- dd_roundtrip(path, ds, say)
    rt <- rt && ok
    say("round trip ", ds, ": ", if (ok) "passed" else "FAILED")
  }
  ok <- bad == 0L && rt
  say("deposit_verify: ", if (ok) "all checks passed" else "problems found")
  invisible(list(ok = ok, files_bad = bad, roundtrip_ok = rt))
}

#' Apply edited metadata tables to a data frame
#'
#' Reads the metadata tables of a deposit (or its codebook .xlsx) after you
#' have edited them and applies labels, value labels, formats, and
#' characteristics to a data frame, the way \code{iecodebook apply} does.
#' Optional columns \code{new_name} and \code{drop} in the variables table
#' rename and drop variables.
#'
#' @param data a data frame.
#' @param source a deposit folder, its metadata folder, or a codebook .xlsx.
#' @param name dataset name when the source holds several.
#' @param types also apply storage types.
#' @param chars also apply characteristics.
#' @return the updated data frame, ready for \code{datadeposit()}.
#' @export
deposit_apply <- function(data, source, name = NULL, types = FALSE, chars = TRUE) {
  if (grepl("\\.xlsx$", source, ignore.case = TRUE)) {
    if (!requireNamespace("readxl", quietly = TRUE)) stop("reading .xlsx needs readxl", call. = FALSE)
    rd <- function(sh) tryCatch(as.data.frame(readxl::read_excel(source, sheet = sh, col_types = "text")),
                                error = function(e) NULL)
    V <- rd("variables"); L <- rd("valuelabels"); C <- rd("chars")
  } else {
    mdir <- if (dir.exists(file.path(source, "metadata"))) file.path(source, "metadata") else source
    if (is.null(name)) {
      st <- sub("_variables\\.csv$", "", list.files(mdir, pattern = "_variables\\.csv$"))
      if (length(st) != 1) stop("pick a dataset with name =", call. = FALSE)
      name <- st
    }
    V <- dd_read_table(file.path(mdir, paste0(name, "_variables.csv")))
    L <- dd_read_table(file.path(mdir, paste0(name, "_valuelabels.csv")))
    C <- dd_read_table(file.path(mdir, paste0(name, "_chars.csv")))
  }
  for (x in c("V", "L", "C")) { y <- get(x); if (!is.null(y)) { y[] <- lapply(y, function(v) { v[is.na(v)] <- ""; v }); assign(x, y) } }
  t <- dd_from_frame(data, if (is.null(name)) "data" else name)
  sn <- vapply(t$columns, `[[`, "", "stata_name")
  if (!is.null(L)) for (s in unique(L$set)) t$value_label_sets[[s]] <- data.frame(value = L$value[L$set == s], label = L$label[L$set == s], stringsAsFactors = FALSE)
  missing <- character(0); drops <- integer(0)
  for (i in seq_len(nrow(V))) {
    key <- if (!is.null(V$stata_name) && nzchar(V$stata_name[i])) V$stata_name[i] else V$name[i]
    k <- match(key, sn)
    if (is.na(k)) { missing <- c(missing, key); next }
    c <- t$columns[[k]]
    c$label <- V$label[i]
    if (!is.null(V$format) && nzchar(V$format[i])) c$format <- V$format[i]
    if (!is.null(V$value_labels)) c$value_labels <- V$value_labels[i]
    if (types && !is.null(V$stata_type) && nzchar(V$stata_type[i])) c$stata_type <- V$stata_type[i]
    if (!is.null(V$drop) && tolower(trimws(V$drop[i])) %in% c("1", "yes", "y", "x", "true")) drops <- c(drops, k)
    if (!is.null(V$new_name) && nzchar(trimws(V$new_name[i]))) { c$name <- trimws(V$new_name[i]); c$stata_name <- c$name }
    t$columns[[k]] <- c
  }
  if (chars && !is.null(C)) {
    for (i in seq_len(nrow(C))) {
      if (grepl("[cut for Excel; full text in", C$text[i], fixed = TRUE)) next
      if (C$variable[i] == "_dta") {
        t$dta_chars <- rbind(t$dta_chars[t$dta_chars$char != C$char[i], , drop = FALSE],
                             data.frame(char = C$char[i], text = C$text[i], stringsAsFactors = FALSE))
      } else {
        k <- match(C$variable[i], sn)
        if (is.na(k)) next
        cc <- t$columns[[k]]$chars
        t$columns[[k]]$chars <- rbind(cc[cc$char != C$char[i], , drop = FALSE],
                                      data.frame(char = C$char[i], text = C$text[i], stringsAsFactors = FALSE))
      }
    }
  }
  if (length(drops)) t$columns <- t$columns[-drops]
  message("deposit_apply: ", nrow(V) - length(missing), " variables updated, ", if (is.null(L)) 0 else nrow(L),
          " value labels, ", if (chars && !is.null(C)) nrow(C) else 0, " characteristics")
  if (length(missing)) message("  in the table but not in the data: ", paste(missing, collapse = " "))
  dd_to_frame(t)
}

dd_to_frame <- function(t) {
  td <- tempfile("ddtf")
  for (s in c("metadata", "data", "setup")) dir.create(file.path(td, s), recursive = TRUE)
  on.exit(unlink(td, recursive = TRUE))
  dd_write_metadata(td, t)
  dd_write_data_csv(file.path(td, "data", paste0(t$name, ".csv")), t)
  dd_write_templates(td, t$name)
  dd_run_setup(td, t$name)
}
