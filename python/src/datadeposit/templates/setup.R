# datadeposit setup file for R (deposit spec 1.0)
# Rebuilds dataset __DATASET__ from data/__DATASET__.csv and the tables in metadata/.
#
# In R, from the deposit folder:
#     source("setup/__DATASET___setup.R")      # creates the data frame `__DATASET__`
#     df <- source("setup/__DATASET___setup.R")$value
# From anywhere in R:
#     options(datadeposit.root = "<deposit>"); source("<deposit>/setup/__DATASET___setup.R")
# From a shell:
#     Rscript setup/__DATASET___setup.R [--root DIR] [--save-rds FILE] [--save-sav FILE]
#
# Needs base R 3.5 or newer and nothing else. When the haven package is
# installed, labelled variables become haven_labelled vectors and extended
# missing codes (.a to .z) become tagged NAs; set options(datadeposit.haven =
# FALSE) to stay in base R, and options(datadeposit.exact_doubles = FALSE) to
# skip the exact-double check (faster on big files; see below). Every label, value label, note, and characteristic
# comes from the metadata tables, so you can edit those tables and rerun.

local({
  ds <- "__DATASET__"
  args <- commandArgs(trailingOnly = TRUE)
  argval <- function(flag) {
    i <- match(flag, args)
    if (is.na(i) || i == length(args)) NULL else args[[i + 1]]
  }

  # ---- find the deposit folder ----------------------------------------------
  has_meta <- function(dir) file.exists(file.path(dir, "metadata", paste0(ds, "_variables.csv")))
  root <- argval("--root")
  if (is.null(root)) root <- getOption("datadeposit.root")
  if (is.null(root)) {
    here <- NULL
    fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
    if (length(fa)) here <- dirname(normalizePath(sub("^--file=", "", fa[1])))
    for (fr in rev(sys.frames())) {
      if (!is.null(fr$ofile)) { here <- dirname(normalizePath(fr$ofile)); break }
    }
    for (cand in c(if (!is.null(here)) dirname(here), ".", "..")) {
      if (has_meta(cand)) { root <- cand; break }
    }
  }
  if (is.null(root) || !has_meta(root)) {
    stop("setup: cannot find metadata/", ds, "_variables.csv; ",
         "setwd() to the deposit folder or set options(datadeposit.root = ...)", call. = FALSE)
  }

  rd <- function(path) {
    utils::read.csv(path, colClasses = "character", na.strings = character(0),
                    check.names = FALSE, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
  }
  meta <- function(tab) {
    f <- file.path(root, "metadata", paste0(ds, "_", tab, ".csv"))
    if (!file.exists(f)) stop("setup: missing ", f, call. = FALSE)
    rd(f)
  }
  vars <- meta("variables")
  vl   <- meta("valuelabels")
  ch   <- meta("chars")
  dsm  <- meta("dataset")
  dkey <- function(k) { v <- dsm$value[dsm$key == k]; if (length(v)) v[[1]] else "" }
  K <- nrow(vars)

  # ---- read the data --------------------------------------------------------
  dfile <- file.path(root, "data", paste0(ds, ".csv"))
  if (!file.exists(dfile)) stop("setup: missing ", dfile, call. = FALSE)
  # integers parse exactly in base R; doubles and floats are read as text and
  # converted below, because base R's parser can miss the last binary digit
  cls <- ifelse(vars$kind == "numeric" & vars$extended_missing != "1" &
                  vars$stata_type %in% c("byte", "int", "long"), "numeric", "character")
  # read.csv turns a carriage return inside quoted text into nothing, so when
  # the file has one (datadeposit writes \n line endings, so any \r is inside
  # text) swap it for a placeholder and put it back after parsing
  has_cr <- FALSE
  sent <- NULL
  con <- file(dfile, "rb")
  repeat {
    chunk <- readBin(con, "raw", 64 * 1024^2)
    if (!length(chunk)) break
    if (any(chunk == as.raw(13))) { has_cr <- TRUE; break }
  }
  close(con)
  if (has_cr && file.size(dfile) < 1e9) {
    txt <- readChar(dfile, file.size(dfile), useBytes = TRUE)
    Encoding(txt) <- "UTF-8"
    sent <- "\uE0CD"
    while (grepl(sent, txt, fixed = TRUE)) sent <- paste0(sent, "\uE0CE")
    txt <- gsub("\r", sent, txt, fixed = TRUE)
    d <- utils::read.csv(text = txt, colClasses = unname(cls), na.strings = character(0),
                         check.names = FALSE, stringsAsFactors = FALSE, encoding = "UTF-8")
    rm(txt)
    for (j in seq_along(d)) {
      if (is.character(d[[j]])) d[[j]] <- gsub(sent, "\r", d[[j]], fixed = TRUE)
    }
  } else {
    if (has_cr) message("setup: note: files over 1 GB are read directly, so carriage returns inside text are dropped")
    d <- utils::read.csv(dfile, colClasses = unname(cls), na.strings = character(0),
                         check.names = FALSE, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
  }
  if (ncol(d) != K) {
    stop("setup: ", dfile, " has ", ncol(d), " columns but the variables table lists ", K, call. = FALSE)
  }
  names(d) <- vars$name

  use_haven <- isTRUE(getOption("datadeposit.haven", TRUE)) &&
    requireNamespace("haven", quietly = TRUE)
  is_tag <- function(x) grepl("^\\.[a-z]$", x)
  sets <- split(vl[c("value", "label")], factor(vl$set, levels = unique(vl$set)))
  set_vector <- function(s) {
    # numeric labels as a named numeric vector; extended codes kept apart
    ext <- is_tag(s$value)
    list(num = stats::setNames(as.numeric(s$value[!ext]), s$label[!ext]),
         ext = stats::setNames(s$value[ext], s$label[ext]))
  }
  qchar <- dkey("question_char")
  chars_for <- function(v) {
    rows <- ch[ch$variable == v, , drop = FALSE]
    isnote <- grepl("^note[0-9]+$", rows$char)
    nn <- rows[isnote & rows$char != "note0", , drop = FALSE]
    nn <- nn[order(as.integer(sub("^note", "", nn$char))), , drop = FALSE]
    other <- rows[!isnote & !rows$char %in% c("datadeposit_label", "datadeposit_name"), , drop = FALSE]
    list(notes = nn$text, chars = stats::setNames(other$text, other$char))
  }

  # >>> exact-double (tools/sync_templates.py copies this block into the R package)
  # The csv holds every double with about 17 significant digits. Base R's
  # parser is not correctly rounded, so each double is checked against its own
  # text and moved to the double whose exact decimal expansion (to 20 digits)
  # is closest to that text.
  sig17 <- function(z) {
    z <- sub("^[-+]", "", z)
    has_e <- grepl("[eE]", z)
    ex <- integer(length(z))
    ex[has_e] <- as.integer(sub("^.*[eE]", "", z[has_e]))
    m <- sub("[eE].*$", "", z)
    ip <- sub("\\..*$", "", m)
    fp <- ifelse(grepl(".", m, fixed = TRUE), sub("^[^.]*\\.", "", m), "")
    dg <- paste0(ip, fp)
    lz <- nchar(dg) - nchar(sub("^0+", "", dg))
    dg <- sub("^0+", "", dg)
    list(d = substr(paste0(dg, strrep("0", 20)), 1, 20), e = ex + nchar(ip) - lz - 1L)
  }
  sig17y <- function(y) {
    z <- sprintf("%.19e", abs(y))
    list(d = paste0(substr(z, 1, 1), substr(z, 3, 21)), e = as.integer(sub("^.*e", "", z)))
  }
  shift1 <- function(x) list(d = paste0("0", substr(x$d, 1, 19)), e = x$e + 1L)
  gap <- function(a, b) {
    part <- function(x, f, l) as.numeric(substr(x, f, l))
    lo <- a$e == b$e + 1L
    hi <- b$e == a$e + 1L
    b2 <- shift1(b)
    a2 <- shift1(a)
    bd <- ifelse(lo, b2$d, b$d)
    ad <- ifelse(hi, a2$d, a$d)
    g <- (part(ad, 1, 8) - part(bd, 1, 8)) * 1e12 + (part(ad, 9, 16) - part(bd, 9, 16)) * 1e4 +
      (part(ad, 17, 20) - part(bd, 17, 20))
    g[abs(a$e - b$e) > 1L] <- NA
    g
  }
  exact_double <- function(txt, y) {
    # integer text below 2^53 always parses exactly; check everything else
    int_txt <- !grepl("[.eE]", txt)
    i <- which(!is.na(y) & is.finite(y) & y != 0 & !(int_txt & abs(y) < 2^53))
    if (!length(i)) return(y)
    # fast path: datadeposit writes doubles as %.17g text (Stata drops the
    # leading zero), so the right double prints back to the same text; a
    # misread is almost always one unit in the last place off
    norm <- function(z) sub("^(-?)0[.]", "\\1.", z)
    tt <- norm(txt[i])
    yi <- y[i]
    j <- which(norm(sprintf("%.17g", yi)) != tt)
    for (k in c(1, -1)) {
      if (!length(j)) break
      cand <- yi[j] + k * 2^(floor(log2(abs(yi[j]))) - 52)
      hit <- norm(sprintf("%.17g", cand)) == tt[j]
      yi[j[hit]] <- cand[hit]
      j <- j[!hit]
    }
    y[i] <- yi
    if (!length(j)) return(y)
    rest <- i[j]
    y[rest] <- exact_slow(txt[rest], y[rest])
    y
  }
  exact_slow <- function(txt, y) {
    i <- seq_along(y)
    w <- sig17(txt[i])
    yi <- y[i]
    act <- seq_along(yi)
    for (iter in 1:4) {
      if (!length(act)) break
      wa <- list(d = w$d[act], e = w$e[act])
      p <- sig17y(yi[act])
      g <- gap(wa, p)
      far <- is.na(g)
      if (any(far)) {
        r <- as.numeric(substr(wa$d[far], 1, 15)) / as.numeric(substr(p$d[far], 1, 15))
        yi[act[far]] <- yi[act[far]] * r * 10^(wa$e[far] - p$e[far])
      }
      big <- !far & abs(g) > 3000
      yi[act[big]] <- yi[act[big]] + sign(yi[act[big]]) * (g[big] * 1e-19) * 10^pmax(wa$e[big], p$e[big])
      act <- act[far | big]
    }
    act <- seq_along(yi)
    for (iter in 1:6) {
      if (!length(act)) break
      wa <- list(d = w$d[act], e = w$e[act])
      ya <- yi[act]
      ulp <- 2^(floor(log2(abs(ya))) - 52)
      g <- abs(gap(wa, sig17y(ya)))
      gu <- abs(gap(wa, sig17y(ya + ulp)))
      gd <- abs(gap(wa, sig17y(ya - ulp)))
      up <- !is.na(gu) & (is.na(g) | gu < g) & (is.na(gd) | gu <= gd)
      dn <- !is.na(gd) & (is.na(g) | gd < g) & !up
      yi[act[up]] <- ya[up] + ulp[up]
      yi[act[dn]] <- ya[dn] - ulp[dn]
      act <- act[up | dn]
    }
    y[i] <- yi
    y
  }
  # <<< exact-double
  as_float32 <- function(y) {
    ok <- !is.na(y)
    y[ok] <- readBin(writeBin(y[ok], raw(), size = 4), "double", size = 4, n = sum(ok))
    y
  }

  nlab <- 0L
  for (j in seq_len(K)) {
    v <- vars[j, ]
    x <- d[[j]]
    ext <- NULL
    if (v$kind != "string") {
      if (is.character(x)) {
        tg <- is_tag(x)
        if (any(tg)) ext <- stats::setNames(which(tg), substr(x[tg], 2, 2))
        x[tg] <- ""
      }
      if (v$kind == "numeric" && is.character(x)) {
        y <- suppressWarnings(as.numeric(x))
        bad <- is.na(y) & x != ""
        if (any(bad)) stop("setup: ", v$name, " has non-numeric values, first: ", x[bad][1], call. = FALSE)
        if (v$stata_type == "double" && isTRUE(getOption("datadeposit.exact_doubles", TRUE))) y <- exact_double(x, y)
        if (v$stata_type == "float") y <- as_float32(y)
        x <- y
      } else if (v$kind == "date") {
        y <- as.Date(ifelse(x == "", NA_character_, x), format = "%Y-%m-%d")
        if (any(is.na(y) & x != "")) stop("setup: ", v$name, " has values that are not dates", call. = FALSE)
        x <- y
      } else if (v$kind == "datetime") {
        y <- as.POSIXct(ifelse(x == "", NA_character_, x), format = "%Y-%m-%d %H:%M:%OS", tz = "UTC")
        if (any(is.na(y) & x != "")) stop("setup: ", v$name, " has values that are not datetimes", call. = FALSE)
        x <- y
      }
    }
    labs <- NULL
    labs_ext <- NULL
    if (nzchar(v$value_labels) && !is.null(sets[[v$value_labels]])) {
      sv <- set_vector(sets[[v$value_labels]])
      labs <- sv$num
      labs_ext <- sv$ext
    }
    if (v$kind == "numeric" && use_haven) {
      if (!is.null(ext)) x[ext] <- haven::tagged_na(names(ext))
      ext <- NULL
      if (!is.null(labs)) {
        if (length(labs_ext)) {
          labs <- c(labs, stats::setNames(haven::tagged_na(substr(labs_ext, 2, 2)), names(labs_ext)))
          labs_ext <- NULL
        }
        x <- haven::labelled(x, labels = labs)
      }
    } else if (!is.null(labs)) {
      attr(x, "labels") <- labs
    }
    if (nzchar(v$label)) { attr(x, "label") <- v$label; nlab <- nlab + 1L }
    attr(x, "format.stata") <- v$format
    cf <- chars_for(v$stata_name)
    if (length(cf$notes)) attr(x, "notes") <- cf$notes
    if (length(cf$chars)) attr(x, "stata_chars") <- cf$chars
    if (nzchar(qchar) && !is.na(cf$chars[qchar])) attr(x, "question") <- unname(cf$chars[qchar])
    if (!is.null(ext)) attr(x, "extended_missing") <- ext
    if (length(labs_ext)) attr(x, "labels_extended") <- labs_ext
    d[[j]] <- x
  }

  # ---- dataset-level attributes ---------------------------------------------
  cf <- chars_for("_dta")
  if (nzchar(dkey("label"))) attr(d, "label") <- dkey("label")
  if (length(cf$notes)) attr(d, "notes") <- cf$notes
  if (length(cf$chars)) attr(d, "stata_chars") <- cf$chars
  attr(d, "datadeposit") <- list(
    dataset = ds, spec = "1.0", root = normalizePath(root),
    sortedby = dkey("sortedby"),
    value_label_sets = lapply(sets, function(s) { sv <- set_vector(s); c(sv$num, if (length(sv$ext)) sv$ext) }),
    variables = vars, valuelabel_rows = vl, char_rows = ch, dataset_table = dsm)

  message("setup: built ", ds, " (", nrow(d), " obs, ", K, " vars, ", nlab,
          " variable labels, ", nrow(vl), " value labels, ", nrow(ch), " characteristics)")

  out <- argval("--save-rds")
  if (!is.null(out)) saveRDS(d, out)
  out <- argval("--save-sav")
  if (!is.null(out)) {
    if (!requireNamespace("haven", quietly = TRUE)) stop("setup: --save-sav needs the haven package", call. = FALSE)
    haven::write_sav(d, out)
  }
  sourced <- any(vapply(sys.frames(), function(fr) !is.null(fr$ofile), logical(1)))
  if ((sourced || interactive()) && isTRUE(getOption("datadeposit.assign", TRUE))) {
    assign(make.names(ds), d, envir = globalenv())
  }
  invisible(d)
})
