# The datadeposit table model and every file writer.
#
# A table holds one dataset in Stata terms: storage types, display formats,
# labels, value label sets, characteristics, and values in Stata units (dates
# are days since 1960, datetimes milliseconds since 1960). Each writer mirrors
# the Mata writer in datadeposit.ado and the Python writer in core.py line for
# line, so a deposit made from R matches one made from Stata or Python.

DD_SPEC <- "1.0"
DD_QUESTION_CHARS <- c("question", "question_text", "qtext", "item", "item_text", "wording", "prompt", "Question")

dd_column <- function(name, stata_name, stata_type, format, label = "", value_labels = "", values,
                      ext = NULL, chars = NULL) {
  if (is.null(chars)) chars <- data.frame(char = character(0), text = character(0), stringsAsFactors = FALSE)
  list(name = name, stata_name = stata_name, stata_type = stata_type, format = format,
       label = if (is.null(label) || is.na(label)) "" else label,
       value_labels = if (is.null(value_labels) || is.na(value_labels)) "" else value_labels,
       values = values, ext = ext, chars = chars)
}

dd_table <- function(name, columns, nobs, label = "", value_label_sets = list(), dta_chars = NULL,
                     sortedby = character(0), source_file = "", question_char = NULL, provenance = "") {
  if (is.null(dta_chars)) dta_chars <- data.frame(char = character(0), text = character(0), stringsAsFactors = FALSE)
  list(name = name, columns = columns, nobs = nobs, label = if (is.null(label)) "" else label,
       value_label_sets = value_label_sets, dta_chars = dta_chars, sortedby = sortedby,
       source_file = source_file, question_char = question_char, provenance = provenance, notes = character(0))
}

dd_kind <- function(stata_type, format) {
  if (startsWith(stata_type, "str")) return("string")
  f <- sub("%-", "%", format, fixed = TRUE)
  if (startsWith(f, "%td") || startsWith(f, "%d")) return("date")
  if (startsWith(f, "%tc") || startsWith(f, "%tC")) return("datetime")
  "numeric"
}

dd_bsort <- function(x) if (!length(x)) character(0) else x[order(x, method = "radix")]

dd_used_sets <- function(tab) {
  used <- character(0)
  for (c in tab$columns) {
    if (nzchar(c$value_labels)) used <- c(used, c$value_labels)
    l <- c$chars$text[startsWith(c$chars$char, "_lang_l_")]
    used <- c(used, l)
  }
  s <- names(tab$value_label_sets)
  dd_bsort(s[s %in% used])
}

dd_stata_chars <- function(tab) {
  v <- rep("_dta", nrow(tab$dta_chars)); n <- tab$dta_chars$char; t <- tab$dta_chars$text
  for (c in tab$columns) {
    v <- c(v, rep(c$stata_name, nrow(c$chars))); n <- c(n, c$chars$char); t <- c(t, c$chars$text)
    if (nchar(c$label) > 80) { v <- c(v, c$stata_name); n <- c(n, "datadeposit_label"); t <- c(t, c$label) }
    if (c$name != c$stata_name) { v <- c(v, c$stata_name); n <- c(n, "datadeposit_name"); t <- c(t, c$name) }
  }
  data.frame(variable = v, char = n, text = t, stringsAsFactors = FALSE)
}

dd_find_qchar <- function(tab) {
  if (!is.null(tab$question_char)) return(tab$question_char)
  for (cand in DD_QUESTION_CHARS) for (c in tab$columns) if (cand %in% c$chars$char) return(cand)
  ""
}

# ---- formatting (identical rules in Stata, R, and Python) -------------------

dd_fmtnum <- function(x) {
  vapply(x, function(v) {
    if (is.na(v)) return("")
    if (v == 0) return("0")
    if (v == floor(v) && abs(v) < 1e15) return(sprintf("%.0f", v))
    sprintf("%.10g", v)
  }, "")
}

dd_vfmt <- function(v) {
  if (is.character(v)) return(v)
  if (v == floor(v)) return(sprintf("%.0f", v))
  dd_fmtnum(v)
}

dd_iso_date <- function(days) format(as.Date(days, origin = "1960-01-01"), "%Y-%m-%d")

dd_iso_datetime <- function(ms) {
  ms <- round(ms)
  secs <- floor(ms / 1000)
  rem <- ms - secs * 1000
  paste0(format(as.POSIXct(secs, origin = "1960-01-01", tz = "UTC"), "%Y-%m-%d %H:%M:%S"),
         sprintf(".%03d", as.integer(rem)))
}

dd_qt <- function(s) paste0('"', gsub('"', '""', s, fixed = TRUE), '"')

dd_write_csv <- function(path, rows) {
  lines <- vapply(rows, function(r) paste(dd_qt(r), collapse = ","), "")
  con <- file(path, "wb")
  on.exit(close(con))
  writeBin(charToRaw(enc2utf8(paste0(paste(lines, collapse = "\n"), "\n"))), con)
}

dd_read_table <- function(path) {
  utils::read.csv(path, colClasses = "character", na.strings = character(0), check.names = FALSE,
                  stringsAsFactors = FALSE, fileEncoding = "UTF-8")
}

dd_spit <- function(path, text) {
  con <- file(path, "wb")
  on.exit(close(con))
  writeBin(charToRaw(enc2utf8(text)), con)
}

dd_meta_path <- function(root, ds, tab) file.path(root, "metadata", paste0(ds, "_", tab, ".csv"))

dd_mdcell <- function(s) {
  s <- gsub("\r\n", "\n", s, fixed = TRUE)
  s <- gsub("|", "\\|", s, fixed = TRUE)
  gsub("\n", "<br>", s, fixed = TRUE)
}

dd_mdquote <- function(s) {
  s <- gsub("\r\n", "\n", s, fixed = TRUE)
  paste0("> ", gsub("\n", "\n> ", s, fixed = TRUE))
}

dd_xml <- function(s) {
  s <- gsub("&", "&amp;", s, fixed = TRUE)
  s <- gsub("<", "&lt;", s, fixed = TRUE)
  s <- gsub(">", "&gt;", s, fixed = TRUE)
  s <- gsub('"', "&quot;", s, fixed = TRUE)
  gsub("[\x01-\x08\x0b\x0c\x0e-\x1f]", "", s, useBytes = FALSE)
}

dd_js <- function(s) {
  s <- gsub("\\", "\\\\", s, fixed = TRUE)
  s <- gsub('"', '\\"', s, fixed = TRUE)
  s <- gsub("\n", "\\n", s, fixed = TRUE)
  s <- gsub("\r", "\\r", s, fixed = TRUE)
  s <- gsub("\t", "\\t", s, fixed = TRUE)
  s <- gsub("\b", "\\b", s, fixed = TRUE)
  s <- gsub("\f", "\\f", s, fixed = TRUE)
  for (k in c(0:7, 11, 14:31)) {
    ch <- intToUtf8(k)
    if (k > 0 && grepl(ch, s, fixed = TRUE)) s <- gsub(ch, sprintf("\\u%04x", k), s, fixed = TRUE)
  }
  paste0('"', s, '"')
}

dd_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S")

# ---- metadata tables ---------------------------------------------------------

dd_sort_entries <- function(s) {
  ext <- grepl("^\\.", s$value)
  num <- s[!ext, , drop = FALSE]
  num <- num[order(as.numeric(num$value)), , drop = FALSE]
  ex <- s[ext, , drop = FALSE]
  ex <- ex[order(ex$value, method = "radix"), , drop = FALSE]
  rbind(num, ex)
}

dd_write_metadata <- function(root, tab) {
  ds <- tab$name
  V <- list(c("position", "name", "stata_name", "stata_type", "kind", "format", "label", "value_labels",
              "extended_missing"))
  for (k in seq_along(tab$columns)) {
    c <- tab$columns[[k]]
    kind <- dd_kind(c$stata_type, c$format)
    ext <- if (kind != "string" && !is.null(c$ext) && any(c$ext > 0)) "1" else "0"
    V[[k + 1L]] <- c(as.character(k), c$name, c$stata_name, c$stata_type, kind, c$format, c$label,
                     c$value_labels, ext)
  }
  dd_write_csv(dd_meta_path(root, ds, "variables"), V)
  L <- list(c("set", "value", "label"))
  for (s in dd_used_sets(tab)) {
    e <- dd_sort_entries(tab$value_label_sets[[s]])
    for (i in seq_len(nrow(e))) L[[length(L) + 1L]] <- c(s, e$value[i], e$label[i])
  }
  dd_write_csv(dd_meta_path(root, ds, "valuelabels"), L)
  C <- list(c("variable", "char", "text"))
  dc <- tab$dta_chars[order(tab$dta_chars$char, method = "radix"), , drop = FALSE]
  for (i in seq_len(nrow(dc))) if (dc$char[i] != "datadeposit_source") C[[length(C) + 1L]] <- c("_dta", dc$char[i], dc$text[i])
  for (c in tab$columns) {
    cc <- c$chars[order(c$chars$char, method = "radix"), , drop = FALSE]
    for (i in seq_len(nrow(cc))) if (!cc$char[i] %in% c("datadeposit_label", "datadeposit_name")) C[[length(C) + 1L]] <- c(c$stata_name, cc$char[i], cc$text[i])
  }
  dd_write_csv(dd_meta_path(root, ds, "chars"), C)
  D <- list(c("key", "value"), c("dataset", ds), c("label", tab$label), c("n_obs", sprintf("%.0f", tab$nobs)),
            c("n_vars", as.character(length(tab$columns))), c("sortedby", paste(tab$sortedby, collapse = " ")),
            c("question_char", dd_find_qchar(tab)), c("source_file", tab$source_file), c("spec_version", DD_SPEC))
  dd_write_csv(dd_meta_path(root, ds, "dataset"), D)
}

dd_write_stats <- function(root, tab) {
  ds <- tab$name
  N <- tab$nobs
  S <- list(c("variable", "kind", "n_valid", "n_missing", "n_extended", "min", "max", "mean", "sd"))
  F <- list(c("variable", "value", "label", "count"))
  for (c in tab$columns) {
    kind <- dd_kind(c$stata_type, c$format)
    if (kind == "string") {
      valid <- sum(c$values != "")
      S[[length(S) + 1L]] <- c(c$stata_name, kind, sprintf("%.0f", valid), sprintf("%.0f", N - valid), "0", "", "", "", "")
      next
    }
    x <- as.double(c$values)
    ext <- if (is.null(c$ext)) integer(N) else c$ext
    nan <- is.na(x)
    n_ext <- sum(ext > 0 & nan)
    sys <- sum(nan) - n_ext
    xv <- x[!nan]
    valid <- length(xv)
    mn <- mx <- me <- sd <- ""
    if (valid) {
      if (kind == "date") { mn <- dd_iso_date(min(xv)); mx <- dd_iso_date(max(xv)) }
      else if (kind == "datetime") { mn <- dd_iso_datetime(min(xv)); mx <- dd_iso_datetime(max(xv)) }
      else {
        mn <- dd_fmtnum(min(xv)); mx <- dd_fmtnum(max(xv)); me <- dd_fmtnum(mean(xv))
        if (valid > 1) sd <- dd_fmtnum(stats::sd(xv))
      }
    }
    S[[length(S) + 1L]] <- c(c$stata_name, kind, sprintf("%.0f", valid), sprintf("%.0f", sys),
                             sprintf("%.0f", n_ext), mn, mx, me, sd)
    if (!nzchar(c$value_labels) || kind != "numeric") next
    e <- tab$value_label_sets[[c$value_labels]]
    if (is.null(e)) e <- data.frame(value = character(0), label = character(0), stringsAsFactors = FALSE)
    lnum <- e[!grepl("^\\.", e$value), , drop = FALSE]
    lext <- e[grepl("^\\.", e$value), , drop = FALSE]
    nums <- sort(unique(c(as.numeric(lnum$value), xv)))
    tok <- sort(unique(c(lext$value, if (any(ext > 0 & nan)) paste0(".", letters[ext[ext > 0 & nan]]))), method = "radix")
    for (v in nums) {
      l <- lnum$label[as.numeric(lnum$value) == v]
      F[[length(F) + 1L]] <- c(c$stata_name, dd_vfmt(v), if (length(l)) l[1] else "", sprintf("%.0f", sum(xv == v)))
    }
    for (v in tok) {
      l <- lext$label[lext$value == v]
      k <- match(substr(v, 2, 2), letters)
      F[[length(F) + 1L]] <- c(c$stata_name, v, if (length(l)) l[1] else "", sprintf("%.0f", sum(ext == k & nan)))
    }
    if (sys) F[[length(F) + 1L]] <- c(c$stata_name, ".", "", sprintf("%.0f", sys))
  }
  dd_write_csv(dd_meta_path(root, ds, "summary"), S)
  dd_write_csv(dd_meta_path(root, ds, "frequencies"), F)
}

# ---- data csv ------------------------------------------------------------------

dd_num_strings <- function(c) {
  x <- as.double(c$values)
  kind <- dd_kind(c$stata_type, c$format)
  out <- rep("", length(x))
  ok <- !is.na(x)
  if (kind == "date") out[ok] <- dd_iso_date(x[ok])
  else if (kind == "datetime") out[ok] <- dd_iso_datetime(x[ok])
  else if (c$stata_type %in% c("byte", "int", "long")) out[ok] <- sprintf("%.0f", x[ok])
  else if (c$stata_type == "float") {
    f <- readBin(writeBin(x[ok], raw(), size = 4), "double", size = 4, n = sum(ok))
    out[ok] <- sprintf("%.9g", f)
  } else out[ok] <- sprintf("%.17g", x[ok])
  if (!is.null(c$ext)) {
    w <- c$ext > 0 & !ok
    out[w] <- paste0(".", letters[c$ext[w]])
  }
  out
}

dd_write_data_csv <- function(path, tab, chunk = 100000L) {
  cols <- lapply(tab$columns, function(c) {
    if (dd_kind(c$stata_type, c$format) == "string") dd_qt(enc2utf8(c$values)) else dd_num_strings(c)
  })
  hdr <- vapply(tab$columns, function(c) {
    n <- c$name
    if (grepl('[,"\r\n]', n) || n != trimws(n)) dd_qt(n) else n
  }, "")
  con <- file(path, "wb")
  on.exit(close(con))
  writeBin(charToRaw(enc2utf8(paste0(paste(hdr, collapse = ","), "\n"))), con)
  N <- tab$nobs
  s <- 1L
  while (s <= N) {
    e <- min(N, s + chunk - 1L)
    rows <- do.call(paste, c(lapply(cols, `[`, s:e), sep = ","))
    writeBin(charToRaw(enc2utf8(paste0(paste(rows, collapse = "\n"), "\n"))), con)
    s <- e + 1L
  }
}

# ---- codebook markdown, DDI, datapackage, README, MANIFEST ----------------------

dd_md_chars <- function(v, C, qchar) {
  isnote <- grepl("^note[0-9]+$", C$char)
  w <- C$variable == v & isnote & C$char != "note0"
  out <- ""
  if (any(w)) {
    nn <- C[w, , drop = FALSE]
    nn <- nn[order(as.integer(substr(nn$char, 5, 99))), , drop = FALSE]
    out <- paste0("**Notes:**\n\n", paste0(seq_len(nrow(nn)), ". ", dd_mdcell(nn$text), "\n", collapse = ""), "\n")
  }
  w <- C$variable == v & !isnote & C$char != qchar
  other <- ""
  if (any(w)) other <- paste0("**Characteristics:**\n\n", paste0("- ", C$char[w], ": ", dd_mdcell(C$text[w]), "\n", collapse = ""), "\n")
  paste0(out, other)
}

dd_opt_table <- function(root, ds, tab) {
  p <- dd_meta_path(root, ds, tab)
  if (file.exists(p)) dd_read_table(p) else NULL
}

dd_kv <- function(root, ds) {
  D <- dd_read_table(dd_meta_path(root, ds, "dataset"))
  stats::setNames(D$value, D$key)
}

dd_write_codebook_md <- function(root, ds) {
  V <- dd_read_table(dd_meta_path(root, ds, "variables"))
  L <- dd_read_table(dd_meta_path(root, ds, "valuelabels"))
  C <- dd_read_table(dd_meta_path(root, ds, "chars"))
  D <- dd_read_table(dd_meta_path(root, ds, "dataset"))
  S <- dd_opt_table(root, ds, "summary")
  F <- dd_opt_table(root, ds, "frequencies")
  dd <- stats::setNames(D$value, D$key)
  dlab <- dd[["label"]]; qchar <- dd[["question_char"]]
  out <- paste0("# Codebook: ", ds, "\n\n")
  if (nzchar(dlab)) out <- paste0(out, dlab, "\n\n")
  out <- paste0(out, "| Item | Value |\n|---|---|\n")
  for (i in seq_len(nrow(D))) {
    if (D$key[i] %in% c("dataset", "label", "spec_version")) next
    out <- paste0(out, "| ", D$key[i], " | ", dd_mdcell(D$value[i]), " |\n")
  }
  out <- paste0(out, "\n")
  t <- dd_md_chars("_dta", C, "")
  if (nzchar(t)) out <- paste0(out, "## Dataset notes and characteristics\n\n", t)
  out <- paste0(out, "## Variables\n\n| # | Name | Label | Type | Value labels |\n|---|---|---|---|---|\n")
  out <- paste0(out, paste0("| ", seq_len(nrow(V)), " | ", V$stata_name, " | ", dd_mdcell(V$label), " | ",
                            V$stata_type, " | ", V$value_labels, " |\n", collapse = ""))
  out <- paste0(out, "\n")
  head <- out
  parts <- character(nrow(V))   # one piece per variable keeps long codebooks linear in time
  for (k in seq_len(nrow(V))) {
    nm <- V$stata_name[k]
    out <- paste0("### ", nm, "\n\n")
    if (nzchar(V$label[k])) out <- paste0(out, "**Label:** ", dd_mdcell(V$label[k]), "\n\n")
    if (nzchar(qchar)) {
      w <- which(C$variable == nm & C$char == qchar)
      for (i in w) out <- paste0(out, "**Question text:**\n\n", dd_mdquote(C$text[i]), "\n\n")
    }
    out <- paste0(out, "**Type:** ", V$stata_type[k], " (", V$kind[k], "), format ", V$format[k], "\n\n")
    if (!is.null(S)) {
      for (i in which(S$variable == nm)) {
        t <- paste0("**Values:** ", S$n_valid[i], " valid, ", S$n_missing[i], if (V$kind[k] == "string") " empty" else " missing")
        if (S$n_extended[i] != "0") t <- paste0(t, ", ", S$n_extended[i], " extended missing")
        if (nzchar(S$min[i])) t <- paste0(t, "; min ", S$min[i], ", max ", S$max[i])
        if (nzchar(S$mean[i])) t <- paste0(t, ", mean ", S$mean[i])
        if (nzchar(S$sd[i])) t <- paste0(t, ", sd ", S$sd[i])
        out <- paste0(out, t, "\n\n")
      }
    }
    if (nzchar(V$value_labels[k])) {
      out <- paste0(out, "**Value labels** (", V$value_labels[k], "):\n\n")
      if (!is.null(F)) {
        out <- paste0(out, "| Value | Label | Count |\n|---|---|---|\n")
        w <- which(F$variable == nm)
        out <- paste0(out, paste0("| ", F$value[w], " | ", dd_mdcell(F$label[w]), " | ", F$count[w], " |\n", collapse = ""))
      } else {
        out <- paste0(out, "| Value | Label |\n|---|---|\n")
        w <- which(L$set == V$value_labels[k])
        out <- paste0(out, paste0("| ", L$value[w], " | ", dd_mdcell(L$label[w]), " |\n", collapse = ""))
      }
      out <- paste0(out, "\n")
    }
    parts[k] <- paste0(out, dd_md_chars(nm, C, qchar))
  }
  dd_spit(file.path(root, "codebook", paste0(ds, "_codebook.md")), paste0(head, paste(parts, collapse = "")))
}

dd_ddistat <- function(type, v) if (nzchar(v)) paste0('      <sumStat type="', type, '">', v, "</sumStat>\n") else ""

dd_write_ddi <- function(root, ds) {
  V <- dd_read_table(dd_meta_path(root, ds, "variables"))
  L <- dd_read_table(dd_meta_path(root, ds, "valuelabels"))
  C <- dd_read_table(dd_meta_path(root, ds, "chars"))
  dd <- dd_kv(root, ds)
  S <- dd_opt_table(root, ds, "summary")
  F <- dd_opt_table(root, ds, "frequencies")
  qchar <- dd[["question_char"]]; dlab <- dd[["label"]]
  out <- '<?xml version="1.0" encoding="UTF-8"?>\n<codeBook xmlns="ddi:codebook:2_5" version="2.5">\n'
  out <- paste0(out, "  <stdyDscr>\n    <citation>\n      <titlStmt>\n        <titl>", dd_xml(if (nzchar(dlab)) dlab else ds), "</titl>\n")
  out <- paste0(out, "      </titlStmt>\n    </citation>\n  </stdyDscr>\n")
  out <- paste0(out, '  <fileDscr ID="F1">\n    <fileTxt>\n      <fileName>', dd_xml(ds), ".csv</fileName>\n")
  out <- paste0(out, "      <dimensns>\n        <caseQnty>", dd[["n_obs"]], "</caseQnty>\n        <varQnty>", dd[["n_vars"]],
                "</varQnty>\n      </dimensns>\n")
  out <- paste0(out, "      <fileType>text/csv</fileType>\n    </fileTxt>\n  </fileDscr>\n  <dataDscr>\n")
  parts <- character(nrow(V))
  for (k in seq_len(nrow(V))) {
    nm <- V$stata_name[k]
    t <- paste0('    <var ID="V', k, '" name="', dd_xml(nm), '" files="F1"')
    if (V$kind[k] == "numeric") t <- paste0(t, ' intrvl="', if (nzchar(V$value_labels[k])) "discrete" else "contin", '"')
    t <- paste0(t, ">\n")
    if (nzchar(V$label[k])) t <- paste0(t, "      <labl>", dd_xml(V$label[k]), "</labl>\n")
    if (nzchar(qchar)) for (i in which(C$variable == nm & C$char == qchar)) {
      t <- paste0(t, "      <qstn>\n        <qstnLit>", dd_xml(C$text[i]), "</qstnLit>\n      </qstn>\n")
    }
    if (!is.null(S)) for (i in which(S$variable == nm)) {
      t <- paste0(t, dd_ddistat("vald", S$n_valid[i]))
      t <- paste0(t, dd_ddistat("invd", sprintf("%.0f", as.numeric(S$n_missing[i]) + as.numeric(S$n_extended[i]))))
      if (V$kind[k] == "numeric") {
        t <- paste0(t, dd_ddistat("min", S$min[i]), dd_ddistat("max", S$max[i]), dd_ddistat("mean", S$mean[i]),
                    dd_ddistat("stdev", S$sd[i]))
      }
    }
    if (nzchar(V$value_labels[k])) {
      if (!is.null(F)) {
        for (i in which(F$variable == nm)) {
          t <- paste0(t, "      <catgry", if (startsWith(F$value[i], ".")) ' missing="Y"' else "", ">\n")
          t <- paste0(t, "        <catValu>", dd_xml(F$value[i]), "</catValu>\n")
          if (nzchar(F$label[i])) t <- paste0(t, "        <labl>", dd_xml(F$label[i]), "</labl>\n")
          t <- paste0(t, '        <catStat type="freq">', F$count[i], "</catStat>\n      </catgry>\n")
        }
      } else {
        for (i in which(L$set == V$value_labels[k])) {
          t <- paste0(t, "      <catgry", if (startsWith(L$value[i], ".")) ' missing="Y"' else "", ">\n")
          t <- paste0(t, "        <catValu>", dd_xml(L$value[i]), "</catValu>\n        <labl>", dd_xml(L$label[i]),
                      "</labl>\n      </catgry>\n")
        }
      }
    }
    t <- paste0(t, '      <varFormat type="', if (V$kind[k] == "string") "character" else "numeric",
                '" schema="other" formatname="', dd_xml(V$format[k]), '"/>\n')
    for (i in which(C$variable == nm & grepl("^note[0-9]+$", C$char) & C$char != "note0")) {
      t <- paste0(t, "      <notes>", dd_xml(C$text[i]), "</notes>\n")
    }
    parts[k] <- paste0(t, "    </var>\n")
  }
  out <- paste0(out, paste(parts, collapse = ""), "  </dataDscr>\n</codeBook>\n")
  dd_spit(file.path(root, "codebook", paste0(ds, "_ddi.xml")), out)
}

dd_clean <- function(s) {
  s <- gsub("[^A-Za-z0-9_-]", "_", trimws(s))
  if (!nzchar(s)) "data" else s
}

dd_write_datapackage <- function(root, stems, info) {
  out <- "{\n"
  out <- paste0(out, '  "name": ', dd_js(tolower(dd_clean(basename(normalizePath(root, mustWork = FALSE))))), ",\n")
  if (nzchar(info$title)) out <- paste0(out, '  "title": ', dd_js(info$title), ",\n")
  if (nzchar(info$description)) out <- paste0(out, '  "description": ', dd_js(info$description), ",\n")
  out <- paste0(out, '  "version": ', dd_js(info$version), ",\n  \"created\": ", dd_js(dd_now()), ",\n")
  if (nzchar(info$authors)) {
    a <- trimws(strsplit(info$authors, ";", fixed = TRUE)[[1]])
    out <- paste0(out, '  "contributors": [\n', paste0('    {"title": ', vapply(a, dd_js, ""), ', "roles": ["author"]}',
                  c(rep(",", length(a) - 1L), ""), "\n", collapse = ""), "  ],\n")
  }
  if (nzchar(info$license)) out <- paste0(out, '  "licenses": [{"name": ', dd_js(info$license), "}],\n")
  out <- paste0(out, '  "resources": [\n')
  for (d in seq_along(stems)) {
    ds <- stems[d]
    V <- dd_read_table(dd_meta_path(root, ds, "variables"))
    L <- dd_read_table(dd_meta_path(root, ds, "valuelabels"))
    C <- dd_read_table(dd_meta_path(root, ds, "chars"))
    dd <- dd_kv(root, ds)
    qchar <- dd[["question_char"]]; dlab <- dd[["label"]]
    out <- paste0(out, "    {\n      \"name\": ", dd_js(tolower(ds)), ",\n      \"path\": ", dd_js(paste0("data/", ds, ".csv")), ",\n")
    if (nzchar(dlab)) out <- paste0(out, '      "title": ', dd_js(dlab), ",\n")
    out <- paste0(out, '      "format": "csv",\n      "mediatype": "text/csv",\n      "encoding": "utf-8",\n')
    out <- paste0(out, '      "schema": {\n        "fields": [\n')
    fl <- character(nrow(V))
    for (k in seq_len(nrow(V))) {
      ftype <- if (V$kind[k] %in% c("string", "date", "datetime")) V$kind[k] else
        if (V$stata_type[k] %in% c("byte", "int", "long")) "integer" else "number"
      t <- paste0("          {\n            \"name\": ", dd_js(V$name[k]), ",\n            \"type\": ", dd_js(ftype), ",\n")
      if (nzchar(V$label[k])) t <- paste0(t, '            "title": ', dd_js(V$label[k]), ",\n")
      if (nzchar(qchar)) for (i in which(C$variable == V$stata_name[k] & C$char == qchar)) {
        t <- paste0(t, '            "description": ', dd_js(C$text[i]), ",\n")
      }
      miss <- '{"value": "", "label": "missing"}'
      if (nzchar(V$value_labels[k])) {
        w <- which(L$set == V$value_labels[k] & !startsWith(L$value, "."))
        if (length(w)) t <- paste0(t, '            "categories": [',
                                   paste0('{"value": ', L$value[w], ', "label": ', vapply(L$label[w], dd_js, ""), "}", collapse = ", "), "],\n")
        w <- which(L$set == V$value_labels[k] & startsWith(L$value, "."))
        if (length(w)) miss <- paste0(miss, paste0(', {"value": ', vapply(L$value[w], dd_js, ""), ', "label": ',
                                                   vapply(L$label[w], dd_js, ""), "}", collapse = ""))
      }
      t <- paste0(t, '            "missingValues": [', miss, "],\n")
      t <- paste0(t, '            "stata": {"name": ', dd_js(V$stata_name[k]), ', "type": ', dd_js(V$stata_type[k]),
                  ', "format": ', dd_js(V$format[k]), ', "valueLabels": ', dd_js(V$value_labels[k]), "}\n")
      fl[k] <- paste0(t, "          }", if (k < nrow(V)) "," else "", "\n")
    }
    out <- paste0(out, paste(fl, collapse = ""), "        ]\n      }\n    }", if (d < length(stems)) "," else "", "\n")
  }
  dd_spit(file.path(root, "datapackage.json"), paste0(out, "  ]\n}\n"))
}

DD_WHAT <- c(
  "^data/.*\\.csv$" = "the data, plain text (codes, not labels)",
  "^data/.*\\.dta$" = "the data for Stata",
  "^data/.*\\.rds$" = "the data for R (base data.frame with attributes)",
  "^data/.*\\.xlsx$" = "the data for Excel (codes sheet and labels sheet)",
  "^data/.*\\.sav$" = "the data for SPSS",
  "_variables\\.csv$" = "one row per variable: type, format, label, value label set",
  "_valuelabels\\.csv$" = "every value label",
  "_chars\\.csv$" = "notes and characteristics, including item text",
  "_dataset\\.csv$" = "dataset label, size, sort order",
  "_summary\\.csv$" = "statistics for each variable",
  "_frequencies\\.csv$" = "counts for every labelled variable",
  "_codebook\\.md$" = "codebook to read",
  "_codebook\\.xlsx$" = "codebook as Excel sheets",
  "_ddi\\.xml$" = "DDI Codebook 2.5 for data archives",
  "_setup\\.do$" = "rebuilds the data in Stata",
  "_setup\\.R$" = "rebuilds the data in R",
  "_setup\\.py$" = "rebuilds the data in Python",
  "^datapackage\\.json$" = "Frictionless Data Package description",
  "^docs/" = "included document")

dd_what <- function(f) {
  for (p in names(DD_WHAT)) if (grepl(p, f)) return(DD_WHAT[[p]])
  ""
}

dd_list_files <- function(root) {
  out <- list.files(root, all.files = FALSE)
  out <- out[!dir.exists(file.path(root, out))]
  for (sub in c("codebook", "data", "docs", "metadata", "setup")) {
    d <- file.path(root, sub)
    if (dir.exists(d)) {
      f <- list.files(d, all.files = FALSE)
      f <- f[!dir.exists(file.path(d, f))]
      if (length(f)) out <- c(out, paste0(sub, "/", f))
    }
  }
  out <- out[out != "MANIFEST.json" & !startsWith(basename(out), ".")]
  dd_bsort(out)
}

dd_write_readme <- function(root, stems, info) {
  fe <- "```"
  fmts <- info$formats
  tit <- if (nzchar(info$title)) info$title else paste0("Data deposit: ", paste(stems, collapse = ", "))
  out <- paste0("# ", tit, "\n\n")
  if (nzchar(info$description)) out <- paste0(out, info$description, "\n\n")
  out <- paste0(out, "This folder is an archive-ready data deposit. It holds the data, a codebook, ",
                "and setup scripts that rebuild the labelled data in Stata, R, and Python from ",
                "the plain-text csv. It was written by datadeposit ", info$package_version, " in ", info$software,
                " on ", dd_now(), ".\n\n")
  out <- paste0(out, "| Item | Value |\n|---|---|\n")
  if (nzchar(info$authors)) out <- paste0(out, "| Authors | ", dd_mdcell(info$authors), " |\n")
  out <- paste0(out, "| Version | ", dd_mdcell(info$version), " |\n| Profile | ", info$profile, " |\n")
  if (nzchar(info$license)) out <- paste0(out, "| License | ", dd_mdcell(info$license), " |\n")
  if (nzchar(info$changes)) out <- paste0(out, "| Changes in this version | ", dd_mdcell(info$changes), " |\n")
  if (nzchar(info$derived)) {
    dp <- c(strsplit(info$derived, "|", fixed = TRUE)[[1]], "", "", "")[1:3]
    out <- paste0(out, "| Derived from | version ", dd_mdcell(dp[2]), " in ", dd_mdcell(dp[1]),
                  " (MANIFEST.json sha256 ", substr(dp[3], 1, 12), ") |\n")
  }
  out <- paste0(out, "\n## Datasets\n\n| Dataset | Label | Observations | Variables |\n|---|---|---|---|\n")
  for (ds in stems) {
    dd <- dd_kv(root, ds)
    out <- paste0(out, "| ", ds, " | ", dd_mdcell(dd[["label"]]), " | ", dd[["n_obs"]], " | ", dd[["n_vars"]], " |\n")
  }
  ds <- stems[1]
  out <- paste0(out, "\n## How to open the data\n\n", "Each dataset has the same files; the examples use `", ds, "`.\n\n")
  out <- paste0(out, "**Stata.** Open the native file, or rebuild it from the csv:\n\n", fe, "stata\n")
  if (file.exists(file.path(root, "data", paste0(ds, ".dta")))) out <- paste0(out, 'use "data/', ds, '.dta", clear\n')
  out <- paste0(out, 'do "setup/', ds, '_setup.do"\n* or, with the datadeposit package installed:\ndatadeposit use ".", clear\n')
  out <- paste0(out, fe, "\n\n**R.** Read the native file, or rebuild it from the csv:\n\n", fe, "r\n")
  if (file.exists(file.path(root, "data", paste0(ds, ".rds")))) out <- paste0(out, ds, ' <- readRDS("data/', ds, '.rds")\n')
  out <- paste0(out, 'source("setup/', ds, '_setup.R")   # creates ', ds, "\n", fe, "\n\n")
  out <- paste0(out, "**Python.** Rebuild it from the csv with pandas:\n\n", fe, "python\nimport runpy\n")
  out <- paste0(out, 'df = runpy.run_path("setup/', ds, '_setup.py")["load"]()\n')
  out <- paste0(out, 'df.attrs["column_names_to_labels"]   # variable labels\n', fe, "\n\n")
  out <- paste0(out, "**Excel.** Open `data/", ds, ".csv` for the values and `codebook/", ds,
                "_codebook.xlsx` for labels, value labels, and question text.\n\n")
  if (info$profile == "lean") out <- paste0(out, "This deposit uses the lean profile: it keeps the native file and one csv, ",
                                            "and the setup scripts build the R and Python versions on demand.\n\n")
  if (info$profile == "nodata") out <- paste0(out, "This deposit holds no data files (nodata profile). The setup scripts expect ",
                                              "the csv at `data/<dataset>.csv`.\n\n")
  out <- paste0(out, "## Files\n\n| File | Bytes | What it is |\n|---|---|---|\n")
  for (f in dd_list_files(root)) {
    if (f %in% c("README.md", "MANIFEST.json")) next
    out <- paste0(out, "| ", f, " | ", format(file.size(file.path(root, f)), big.mark = ",", scientific = FALSE),
                  " | ", dd_what(f), " |\n")
  }
  out <- paste0(out, "| MANIFEST.json | | sizes and sha256 hashes of every file |\n")
  out <- paste0(out, "\n## Checking and changing this deposit\n\n",
                'Run `datadeposit verify "<this folder>"` (Stata) or `deposit_verify()` (R or Python) to confirm ',
                "that no file changed and that the csv still rebuilds the data exactly.\n\n",
                "Do not edit files here. To publish changed data, load it with `datadeposit use`, make the changes, ",
                "and write a new deposit with `version()` and `changes()`; the new deposit records this one as its parent.\n\n",
                "Folder layout and rules: deposit specification 1.0, https://github.com/ericabooth/datadeposit\n")
  dd_spit(file.path(root, "README.md"), out)
}

dd_sha256 <- function(path) {
  if (exists("sha256sum", envir = asNamespace("tools"))) return(unname(get("sha256sum", envir = asNamespace("tools"))(path)))
  if (requireNamespace("digest", quietly = TRUE)) return(digest::digest(file = path, algo = "sha256"))
  out <- tryCatch(system2("shasum", c("-a", "256", shQuote(path)), stdout = TRUE), error = function(e) "")
  sub(" .*$", "", out[1])
}

dd_write_manifest <- function(root, stems, info, engines, hash = TRUE) {
  files <- dd_list_files(root)
  out <- "{\n  \"datadeposit\": \"1.0\",\n"
  out <- paste0(out, '  "package": ', dd_js(paste("datadeposit", info$package_version)), ",\n")
  out <- paste0(out, '  "software": ', dd_js(info$software), ",\n  \"created\": ", dd_js(dd_now()), ",\n")
  out <- paste0(out, '  "title": ', dd_js(info$title), ",\n  \"version\": ", dd_js(info$version), ",\n  \"changes\": ",
                dd_js(info$changes), ",\n  \"profile\": ", dd_js(info$profile), ",\n")
  if (!nzchar(info$derived)) out <- paste0(out, '  "derived_from": null,\n') else {
    p <- c(strsplit(info$derived, "|", fixed = TRUE)[[1]], "", "", "")[1:3]
    out <- paste0(out, '  "derived_from": {"path": ', dd_js(p[1]), ', "version": ', dd_js(p[2]),
                  ', "manifest_sha256": ', dd_js(p[3]), "},\n")
  }
  out <- paste0(out, '  "size_check": {"max_gb": ', dd_fmtnum(info$max_gb), ', "largest_file_gb": ',
                dd_fmtnum(round(info$largest / 1e9, 3)), ', "override": ', dd_js(info$size_override), "},\n")
  out <- paste0(out, '  "datasets": [', paste(vapply(stems, dd_js, ""), collapse = ", "), "],\n  \"files\": [\n")
  ent <- vapply(seq_along(files), function(i) {
    f <- files[i]
    p <- file.path(root, f)
    eng <- if (!is.null(engines[[f]])) engines[[f]] else info$engine
    paste0('    {"path": ', dd_js(f), ', "bytes": ', sprintf("%.0f", file.size(p)), ', "sha256": ',
           dd_js(if (hash) dd_sha256(p) else ""), ', "engine": ', dd_js(eng), "}", if (i < length(files)) "," else "", "\n")
  }, "")
  dd_spit(file.path(root, "MANIFEST.json"), paste0(out, paste(ent, collapse = ""), "  ]\n}\n"))
  dd_sha256(file.path(root, "MANIFEST.json"))
}
