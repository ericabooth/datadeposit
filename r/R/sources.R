# Turn what an R user has into a datadeposit table: a .dta file (read with
# full metadata), a data frame from deposit_use() or a deposit's setup.R (its
# "datadeposit" attribute carries the exact metadata, so a deposit can be
# re-deposited without loss), a haven-labelled data frame, or any data frame.

DD_RESERVED <- c("_dta", "_all", "_b", "byte", "_coef", "_cons", "double", "float", "if", "in", "int", "long", "_n",
                 "_N", "_pi", "_pred", "_rc", "_skip", "strL", "using", "with")

dd_stem <- function(path) dd_clean(tools::file_path_sans_ext(sub("\\.gz$", "", basename(path), ignore.case = TRUE)))

dd_stata_names <- function(x) {
  out <- character(length(x))
  seen <- character(0)
  for (i in seq_along(x)) {
    s <- gsub("[^A-Za-z0-9_]", "_", x[i])
    if (!nzchar(s) || grepl("^[0-9]", s)) s <- paste0("_", s)
    if (s %in% DD_RESERVED || grepl("^str[0-9]+$", s)) s <- paste0(s, "_")
    s <- substr(s, 1, 32)
    base <- s
    k <- 2L
    while (s %in% seen) {
      suf <- paste0("_", k)
      s <- paste0(substr(base, 1, 32 - nchar(suf)), suf)
      k <- k + 1L
    }
    seen <- c(seen, s)
    out[i] <- s
  }
  out
}

dd_empty_chars <- function() data.frame(char = character(0), text = character(0), stringsAsFactors = FALSE)

dd_from_dta <- function(path, name = dd_stem(path)) {
  r <- dd_read_dta(path)
  ch <- r$chars
  prov <- ch$text[ch$variable == "_dta" & ch$char == "datadeposit_source"]
  dc <- ch[ch$variable == "_dta" & ch$char != "datadeposit_source", c("char", "text")]
  cols <- vector("list", r$K)
  for (i in seq_len(r$K)) {
    nm <- r$names[i]
    cc <- ch[ch$variable == nm, c("char", "text")]
    lab <- r$varlabels[i]
    full <- cc$text[cc$char == "datadeposit_label"]
    if (length(full) && substr(full[1], 1, 80) == lab) lab <- full[1]
    orig <- cc$text[cc$char == "datadeposit_name"]
    cc <- cc[!cc$char %in% c("datadeposit_label", "datadeposit_name"), , drop = FALSE]
    rownames(cc) <- NULL
    cols[[i]] <- dd_column(if (length(orig)) orig[1] else nm, nm, dd_type_name(r$types[i]), r$formats[i], lab, r$vlnames[i],
                           r$data$values[[i]], r$data$ext[[i]], cc)
  }
  rownames(dc) <- NULL
  dd_table(name, cols, r$N, r$label, r$value_labels, dc, r$sortlist, basename(path),
           provenance = if (length(prov)) prov[1] else "")
}

dd_int_type <- function(x) {
  v <- x[!is.na(x)]
  if (length(v) && any(v != floor(v))) return(NULL)
  lo <- if (length(v)) min(v) else 0
  hi <- if (length(v)) max(v) else 0
  if (lo >= -127 && hi <= 100) return("byte")
  if (lo >= -32767 && hi <= 32740) return("int")
  if (lo >= -2147483647 && hi <= 2147483620) return("long")
  NULL
}

dd_default_format <- function(t) {
  if (startsWith(t, "str") && t != "strL") return(sprintf("%%%ds", max(9L, as.integer(substr(t, 4, 9)))))
  switch(t, byte = "%8.0g", int = "%8.0g", long = "%12.0g", float = "%9.0g", double = "%10.0g", strL = "%9s")
}

dd_text <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  enc2utf8(x)
}

dd_str_type <- function(v) {
  w <- max(c(nchar(v, type = "bytes"), 1L))
  if (w > 2045) "strL" else paste0("str", w)
}

dd_to_stata_units <- function(x, kind) {
  if (kind == "date") return(as.double(as.Date(x)) + 3653)
  if (kind == "datetime") return(round((as.double(as.POSIXct(x, tz = "UTC")) + 315619200) * 1000))
  as.double(unclass(x))
}

dd_tags <- function(x) {
  if (requireNamespace("haven", quietly = TRUE) && is.double(x)) {
    tg <- haven::na_tag(x)
    k <- match(tg, letters)
    k[is.na(k)] <- 0L
    if (any(k > 0)) return(as.integer(k))
  }
  NULL
}

dd_infer_column <- function(x, name, stata_name) {
  lab <- attr(x, "label", exact = TRUE)
  if (is.null(lab)) lab <- ""
  fmt0 <- attr(x, "format.stata", exact = TRUE)
  if (is.factor(x)) {
    codes <- as.double(as.integer(x))
    typ <- dd_int_type(codes)
    lv <- levels(x)
    set <- data.frame(value = as.character(seq_along(lv)), label = lv, stringsAsFactors = FALSE)
    return(list(col = dd_column(name, stata_name, typ, dd_default_format(typ), lab, stata_name, codes), sets = stats::setNames(list(set), stata_name)))
  }
  if (is.logical(x)) return(list(col = dd_column(name, stata_name, "byte", "%8.0g", lab, "", as.double(x)), sets = list()))
  if (inherits(x, "POSIXct")) return(list(col = dd_column(name, stata_name, "double", "%tc", lab, "", dd_to_stata_units(x, "datetime")), sets = list()))
  if (inherits(x, "Date")) return(list(col = dd_column(name, stata_name, "long", "%td", lab, "", dd_to_stata_units(x, "date")), sets = list()))
  if (is.numeric(x)) {
    ext <- dd_tags(x)
    v <- as.double(unclass(x))
    attributes(v) <- NULL
    typ <- if (is.integer(x)) (dd_int_type(v) %||% "double") else (dd_int_type(v) %||% "double")
    labs <- attr(x, "labels", exact = TRUE)
    sets <- list()
    vl <- ""
    if (!is.null(labs) && is.numeric(labs)) {
      tg <- if (requireNamespace("haven", quietly = TRUE)) haven::na_tag(labs) else rep(NA_character_, length(labs))
      val <- ifelse(is.na(tg), sprintf("%.0f", unclass(labs)), paste0(".", tg))
      keep <- !is.na(tg) | (!is.na(unclass(labs)) & unclass(labs) == floor(unclass(labs)))
      sets[[stata_name]] <- data.frame(value = val[keep], label = names(labs)[keep], stringsAsFactors = FALSE)
      vl <- stata_name
      hi <- suppressWarnings(max(abs(as.numeric(val[keep & is.na(tg)])), 0))
      if (typ == "byte" && hi > 100) typ <- "int"
      if (typ %in% c("byte", "int") && hi > 32740) typ <- "long"
    }
    fmt <- if (!is.null(fmt0)) fmt0 else dd_default_format(typ)
    kind <- dd_kind(typ, fmt)
    return(list(col = dd_column(name, stata_name, typ, fmt, lab, vl, v, ext), sets = sets))
  }
  v <- dd_text(x)
  typ <- dd_str_type(v)
  list(col = dd_column(name, stata_name, typ, dd_default_format(typ), lab, "", v), sets = list())
}

`%||%` <- function(a, b) if (is.null(a)) b else a

DD_STATA_MAX <- 8.988465674311579e307

# Fix what Stata cannot store, before any type is chosen, and say what changed.
dd_clean_frame <- function(df) {
  notes <- character(0)
  if (!ncol(df)) stop("the data have no columns", call. = FALSE)
  dd <- attr(df, "datadeposit", exact = TRUE)
  lab <- attr(df, "label", exact = TRUE)
  df <- as.data.frame(df, stringsAsFactors = FALSE, optional = TRUE)
  nm <- names(df)
  if (is.null(nm)) nm <- rep("", ncol(df))
  nm[is.na(nm) | !nzchar(trimws(nm))] <- paste0("v", which(is.na(nm) | !nzchar(trimws(nm))))
  if (anyDuplicated(nm)) stop("column names must be unique; rename the repeated column(s): ",
                              paste(unique(nm[duplicated(nm)]), collapse = ", "), call. = FALSE)
  names(df) <- nm
  for (j in seq_along(df)) {
    x <- df[[j]]
    a <- attributes(x)
    if (is.list(x) && !is.data.frame(x)) {
      df[[j]] <- vapply(x, function(v) if (is.null(v) || (length(v) == 1 && is.na(v))) "" else paste(deparse(v), collapse = " "), "")
      notes <- c(notes, paste0(nm[j], " was a list column; its values were stored as text"))
    } else if (inherits(x, "integer64")) {
      df[[j]] <- ifelse(is.na(x), "", as.character(x))
      notes <- c(notes, paste0(nm[j], " held 64-bit integers, which a double cannot keep exactly; it was stored as text"))
    } else if (inherits(x, "difftime")) {
      df[[j]] <- as.double(x, units = "secs")
      notes <- c(notes, paste0(nm[j], " held time spans; they were stored as seconds"))
    } else if (is.complex(x)) {
      df[[j]] <- ifelse(is.na(x), "", as.character(x))
      notes <- c(notes, paste0(nm[j], " held complex numbers; they were stored as text"))
    } else if (inherits(x, "POSIXt")) {
      tz <- attr(as.POSIXct(x), "tzone")
      if (length(tz) && nzchar(tz[1]) && !tz[1] %in% c("UTC", "GMT")) notes <- c(notes, paste0(nm[j], " had time zone ", tz[1], "; it was converted to UTC"))
      if (inherits(x, "POSIXlt")) df[[j]] <- as.POSIXct(x)
    } else if (is.character(x) && !is.null(a$labels)) {
      notes <- c(notes, paste0(nm[j], " is text with value labels; Stata labels only numbers, so the labels were dropped"))
      df[[j]] <- as.character(unclass(x))
      if (!is.null(a$label)) attr(df[[j]], "label") <- a$label
    } else if (is.double(x) && !inherits(x, "Date")) {
      bad <- is.infinite(x) | (!is.na(x) & abs(x) > DD_STATA_MAX)
      tagged <- if (requireNamespace("haven", quietly = TRUE)) !is.na(haven::na_tag(x)) else rep(FALSE, length(x))
      bad <- bad & !tagged
      if (any(bad, na.rm = TRUE)) {
        x[which(bad)] <- NA_real_
        df[[j]] <- x
        notes <- c(notes, sprintf("%s had %d infinite or out-of-range values that Stata cannot store; they are missing in the deposit", nm[j], sum(bad, na.rm = TRUE)))
      }
    }
  }
  attr(df, "datadeposit") <- dd
  attr(df, "label") <- lab
  list(df = df, notes = notes)
}

dd_from_frame <- function(df, name = "data", source_file = "") {
  cl <- dd_clean_frame(df)
  t <- dd_from_frame0(cl$df, name, source_file)
  t$notes <- c(cl$notes, t$notes)
  t
}

dd_from_frame0 <- function(df, name = "data", source_file = "") {
  dd <- attr(df, "datadeposit", exact = TRUE)
  if (!is.null(dd) && !is.null(dd$variables)) return(dd_from_deposit_frame(df, name, dd, source_file))
  nms <- names(df)
  sn <- dd_stata_names(nms)
  cols <- vector("list", length(nms))
  sets <- list()
  for (i in seq_along(nms)) {
    r <- dd_infer_column(df[[i]], nms[i], sn[i])
    cols[[i]] <- r$col
    sets <- c(sets, r$sets)
  }
  lab <- attr(df, "label", exact = TRUE)
  dd_table(name, cols, nrow(df), if (is.null(lab)) "" else lab, sets, NULL, character(0), source_file)
}

dd_from_deposit_frame <- function(df, name, dd, source_file) {
  vars <- dd$variables
  ch <- dd$char_rows
  vlr <- dd$valuelabel_rows
  dt <- dd$dataset_table
  dkey <- function(k) { v <- dt$value[dt$key == k]; if (length(v)) v[1] else "" }
  sets <- list()
  for (s in unique(vlr$set)) {
    sets[[s]] <- data.frame(value = vlr$value[vlr$set == s], label = vlr$label[vlr$set == s], stringsAsFactors = FALSE)
  }
  newc <- setdiff(names(df), vars$name)
  newsn <- stats::setNames(dd_stata_names(newc), newc)
  cols <- list()
  for (nm in names(df)) {
    x <- df[[nm]]
    i <- match(nm, vars$name)
    if (is.na(i)) {
      r <- dd_infer_column(x, nm, newsn[[nm]])
      cols[[length(cols) + 1L]] <- r$col
      sets <- c(sets, r$sets)
      next
    }
    v <- vars[i, ]
    typ <- v$stata_type
    if (v$kind == "string") {
      vals <- dd_text(x)
      ext <- NULL
      if (typ != "strL") {
        w <- max(c(nchar(vals, type = "bytes"), 1L))
        if (w > as.integer(substr(typ, 4, 9))) typ <- if (w > 2045) "strL" else paste0("str", w)
      }
    } else {
      if (is.factor(x)) {
        s <- sets[[v$value_labels]]
        x <- as.double(s$value[match(as.character(x), s$label)])
      }
      ext <- NULL
      if (v$kind == "numeric") ext <- dd_tags(x)
      em <- attr(x, "extended_missing", exact = TRUE)
      vals <- dd_to_stata_units(x, v$kind)
      attributes(vals) <- NULL
      if (!is.null(em)) {
        ext <- integer(length(vals))
        ext[em] <- match(names(em), letters)
      }
      if (v$kind == "numeric" && typ %in% c("byte", "int", "long")) {
        it <- dd_int_type(vals)
        ord <- c("byte", "int", "long")
        if (is.null(it)) typ <- "double" else if (match(it, ord) > match(typ, ord)) typ <- it
      }
    }
    cc <- ch[ch$variable == v$stata_name, c("char", "text"), drop = FALSE]
    rownames(cc) <- NULL
    cols[[length(cols) + 1L]] <- dd_column(nm, v$stata_name, typ, v$format, v$label, v$value_labels, vals, ext, cc)
  }
  dc <- ch[ch$variable == "_dta" & ch$char != "datadeposit_source", c("char", "text"), drop = FALSE]
  rownames(dc) <- NULL
  sn <- vapply(cols, `[[`, "", "stata_name")
  sb <- strsplit(dkey("sortedby"), " ", fixed = TRUE)[[1]]
  qc <- dkey("question_char")
  dd_table(name, cols, nrow(df), dkey("label"), sets, dc, sb[sb %in% sn],
           if (nzchar(source_file)) source_file else dkey("source_file"),
           question_char = if (nzchar(qc)) qc else NULL,
           provenance = if (is.null(dd$provenance)) "" else dd$provenance)
}

dd_read_any <- function(path, name = dd_stem(path)) {
  base <- basename(path)
  ext <- tolower(tools::file_ext(path))
  sn <- dd_sniff(path)
  if (!sn$is_data) stop(base, " is not a data file: ", sn$why, call. = FALSE)
  notes <- character(0)
  expect <- list(dta = c("dta", "dta_old"), csv = "delimited", tsv = "delimited", txt = "delimited",
                 xlsx = "xlsx", xls = c("xls", "xlsx"), sav = "sav", parquet = "parquet", rds = "rds")
  if (!is.null(expect[[ext]]) && !sn$kind %in% expect[[ext]]) notes <- c(notes, paste0(base, " is really a ", sn$kind, " file; read it as one"))
  need <- function(pkg, what) if (!requireNamespace(pkg, quietly = TRUE))
    stop(base, " is ", what, "; reading it needs the ", pkg, " package: install.packages(\"", pkg, "\")", call. = FALSE)
  t <- switch(sn$kind,
    dta = dd_from_dta(path, name),
    dta_old = {
      need("haven", "a Stata file older than format 13")
      notes <- c(notes, paste0(base, " uses a Stata format older than 13, so its notes and characteristics were not read; ",
                               "open it in Stata 14 or newer and save it again to keep them"))
      dd_from_frame(haven::read_dta(path), name, base)
    },
    delimited = , gzip = {
      r <- dd_read_delimited(path, sn, notes)
      notes <- r$notes
      dd_from_frame(r$data, name, base)
    },
    xlsx = , xls = {
      need("readxl", "an Excel file")
      sh <- readxl::excel_sheets(path)
      if (length(sh) > 1) notes <- c(notes, sprintf("%s has %d sheets; only the first (%s) was deposited", base, length(sh), sh[1]))
      dd_from_frame(as.data.frame(readxl::read_excel(path, sheet = 1)), name, base)
    },
    sav = { need("haven", "an SPSS file"); dd_from_frame(haven::read_spss(path), name, base) },
    rds = {
      x <- readRDS(path)
      if (!is.data.frame(x)) stop(base, " holds an R object of class ", class(x)[1], ", not a data frame", call. = FALSE)
      dd_from_frame(x, name, base)
    },
    parquet = stop(base, " is a Parquet file; read it with arrow::read_parquet() and deposit the data frame", call. = FALSE),
    stop(base, ": unsupported file type ", sn$kind, call. = FALSE))
  t$notes <- c(notes, t$notes)
  t
}
