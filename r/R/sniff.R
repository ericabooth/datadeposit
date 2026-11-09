# Identify a file by its contents, not its name (same rules as sniff.py).
#
# Shared folders hold .txt files that are really pipe-delimited tables, .csv
# files saved in Latin-1, Stata files renamed to .txt, and code or notes
# beside the data. dd_sniff() reads the first 64 KB and says what the file is,
# so datadeposit can read a table whatever it is called and explain why it
# skips anything that is not one.

DD_CODE_EXT <- c("do", "ado", "r", "rmd", "qmd", "py", "ipynb", "sas", "sps", "m", "jl", "sql", "sh", "md",
                 "tex", "log", "smcl", "pdf", "docx", "doc", "html", "png", "jpg", "gif", "svg", "json",
                 "xml", "yaml", "yml")

dd_sniff_result <- function(kind, why = "", delim = NULL, encoding = NULL, decimal = ".") {
  list(kind = kind, why = why, delim = delim, encoding = encoding, decimal = decimal,
       is_data = kind %in% c("dta", "dta_old", "delimited", "xlsx", "xls", "sav", "parquet", "rds", "gzip"))
}

dd_starts <- function(head, bytes) length(head) >= length(bytes) && identical(head[seq_along(bytes)], as.raw(bytes))

dd_sniff <- function(path) {
  ext0 <- sub("^.*\\.", ".", basename(path))
  if (!grepl("\\.", basename(path))) ext0 <- ""
  ext <- tolower(sub("^\\.", "", ext0))
  if (!file.exists(path)) return(dd_sniff_result("missing", "the file does not exist"))
  if (file.size(path) == 0) return(dd_sniff_result("empty", "the file is empty"))
  con <- file(path, "rb")
  head <- readBin(con, "raw", 65536)
  close(con)
  if (dd_starts(head, charToRaw("<stata_dta>"))) return(dd_sniff_result("dta"))
  if (length(head) > 2 && as.integer(head[1]) %in% c(104, 105, 108, 110, 111, 113, 114, 115) &&
      as.integer(head[2]) %in% c(1, 2) && as.integer(head[3]) == 1) return(dd_sniff_result("dta_old"))
  if (dd_starts(head, c(0x50, 0x4b, 0x03, 0x04))) {
    if (length(grepRaw("xl/", head, fixed = TRUE)) || ext %in% c("xlsx", "xlsm")) return(dd_sniff_result("xlsx"))
    return(dd_sniff_result("zip", "the file is a zip archive; unzip it first"))
  }
  if (dd_starts(head, c(0xd0, 0xcf, 0x11, 0xe0))) {
    if (ext %in% c("doc", "ppt", "msg")) return(dd_sniff_result("document", "the file is an Office document, not a table"))
    return(dd_sniff_result("xls"))
  }
  if (dd_starts(head, charToRaw("$FL2")) || dd_starts(head, charToRaw("$FL3"))) return(dd_sniff_result("sav"))
  if (dd_starts(head, charToRaw("PAR1"))) return(dd_sniff_result("parquet"))
  if (dd_starts(head, charToRaw("%PDF"))) return(dd_sniff_result("document", "the file is a PDF; add it with include = to ship it in docs/"))
  if (dd_starts(head, c(0x89, 0x50, 0x4e, 0x47)) || dd_starts(head, c(0xff, 0xd8, 0xff)) || dd_starts(head, charToRaw("GIF8"))) {
    return(dd_sniff_result("document", "the file is an image; add it with include = to ship it in docs/"))
  }
  if (dd_starts(head, c(0x1f, 0x8b))) return(dd_sniff_result(if (ext == "rds") "rds" else "gzip"))
  if (dd_starts(head, charToRaw("RDX2\n")) || dd_starts(head, charToRaw("RDX3\n")) ||
      dd_starts(head, charToRaw("X\n")) || dd_starts(head, charToRaw("A\n"))) return(dd_sniff_result("rds"))
  enc <- "UTF-8"
  if (dd_starts(head, c(0xff, 0xfe)) || dd_starts(head, c(0xfe, 0xff))) {
    enc <- "UTF-16"
    txt <- iconv(list(head), "UTF-16", "UTF-8")
  } else if (any(head == as.raw(0))) {
    return(dd_sniff_result("binary", paste0("the file holds binary data, not text, though its name ends in ",
                                            if (nzchar(ext0)) ext0 else "nothing")))
  } else {
    if (dd_starts(head, c(0xef, 0xbb, 0xbf))) { head <- head[-(1:3)]; enc <- "UTF-8-BOM" }
    txt <- rawToChar(head)
    Encoding(txt) <- "UTF-8"
    if (!validUTF8(txt)) {
      cut <- if (length(head) == 65536) head[seq_len(max(1, length(head) - 4))] else head
      t2 <- rawToChar(cut); Encoding(t2) <- "UTF-8"
      if (length(head) == 65536 && validUTF8(t2)) txt <- t2 else {
        txt <- iconv(rawToChar(head), "latin1", "UTF-8"); enc <- "latin1"
      }
    }
  }
  if (ext %in% DD_CODE_EXT) {
    return(dd_sniff_result("code", paste0("the file is code or documentation (", ext0, "); add it with include = to ship it in docs/")))
  }
  if (length(head) == 65536) txt <- sub("\n[^\n]*$", "\n", txt)
  if (!nzchar(trimws(txt))) return(dd_sniff_result("empty", "the file holds only blank lines"))
  recs <- function(d) {
    cnt <- tryCatch(utils::count.fields(textConnection(txt), sep = d, quote = "\"", comment.char = "",
                                        blank.lines.skip = TRUE), error = function(e) integer(0))
    cnt <- cnt[!is.na(cnt)]
    cnt[seq_len(min(200, length(cnt)))]
  }
  best <- NULL
  for (d in c(",", "\t", "|", ";")) {
    cnt <- recs(d)
    if (!length(cnt)) next
    if (cnt[1] > 1 && all(cnt == cnt[1]) && (is.null(best) || cnt[1] > best$n)) best <- list(d = d, n = cnt[1])
  }
  if (is.null(best)) {
    multi <- Filter(function(z) length(z$cnt) && z$cnt[1] > 1, lapply(c(",", "\t", "|", ";"), function(d) list(d = d, cnt = recs(d))))
    if (length(multi)) {
      m <- multi[[which.max(vapply(multi, function(z) z$cnt[1], numeric(1)))]]
      bad <- which(m$cnt != m$cnt[1])[1]
      return(dd_sniff_result("ragged", sprintf("record %d has %d fields but the header has %d (delimiter '%s'); fix the file or read it yourself",
                                               bad, m$cnt[bad], m$cnt[1], m$d)))
    }
    lines <- strsplit(txt, "\r?\n|\r")[[1]]
    lines <- lines[nzchar(trimws(lines))]
    if (ext %in% c("csv", "tsv", "txt", "psv", "dat") && grepl("^[A-Za-z_][A-Za-z0-9_]{0,31}$", trimws(lines[1])) &&
        all(nchar(lines) <= 80)) return(dd_sniff_result("delimited", delim = ",", encoding = enc))
    return(dd_sniff_result("text", "the file is text with no consistent delimiter (comma, tab, pipe, or semicolon), so it does not look like a table"))
  }
  dec <- "."
  if (best$d == ";" && grepl("(^|;)\\s*-?[0-9]+,[0-9]+\\s*(;|\r?\n|$)", sub("^[^\n]*\n", "", txt))) dec <- ","
  dd_sniff_result("delimited", delim = best$d, encoding = enc, decimal = dec)
}

# Read a delimited text file as text, then turn columns into numbers only
# when every value is a number and none has a leading zero.
dd_read_delimited <- function(path, sn, notes) {
  base <- basename(path)
  if (sn$kind == "gzip") {
    tf <- tempfile(fileext = ".txt")
    on.exit(unlink(tf), add = TRUE)
    zc <- gzfile(path, "rb"); writeBin(readBin(zc, "raw", 65536), tf); close(zc)
    sn2 <- dd_sniff(tf)
    if (sn2$kind != "delimited") stop(base, " is compressed, and what it holds is not a delimited table: ", sn2$why, call. = FALSE)
    sn <- sn2
    con <- gzfile(path, encoding = sub("-BOM$", "", sn$encoding))
  } else {
    con <- file(path, encoding = if (sn$encoding == "UTF-8-BOM") "UTF-8-BOM" else sn$encoding)
  }
  # quote marks count as quoting only when some field starts with one; otherwise
  # they are text (Bo "B" Lee), as Python's csv module and Stata read them
  probe <- readLines(if (sn$kind == "gzip") gzfile(path) else file(path, encoding = sub("-BOM$", "", sn$encoding)), n = 2000, warn = FALSE)
  esc <- if (sn$delim == "|") "\\|" else sn$delim
  q <- if (any(grepl(paste0("(^|", esc, ")\\s*\""), probe))) "\"" else ""
  d <- tryCatch(utils::read.table(con, sep = sn$delim, quote = q, header = TRUE, colClasses = "character",
                                  comment.char = "", check.names = FALSE, na.strings = character(0),
                                  strip.white = FALSE, blank.lines.skip = TRUE, stringsAsFactors = FALSE),
                error = function(e) stop(base, " could not be read as a '", sn$delim, "'-delimited table: ", conditionMessage(e), call. = FALSE))
  nm <- names(d)
  nm[!nzchar(trimws(nm))] <- paste0("v", which(!nzchar(trimws(nm))))
  dup <- duplicated(nm)
  for (k in which(dup)) {
    i <- 2L
    while (paste0(nm[k], "_", i) %in% nm) i <- i + 1L
    notes <- c(notes, sprintf("%s repeats the column name '%s'; the repeat is named '%s'", base, nm[k], paste0(nm[k], "_", i)))
    nm[k] <- paste0(nm[k], "_", i)
  }
  names(d) <- nm
  if (sn$encoding == "latin1") notes <- c(notes, paste0(base, " is not UTF-8; it was read as Latin-1 (Windows-1252) and the deposit is UTF-8"))
  if (sn$delim != ",") notes <- c(notes, sprintf("%s is delimited by '%s'; the deposit's csv uses commas", base, sn$delim))
  if (sn$decimal == ",") notes <- c(notes, paste0(base, " writes decimals with a comma; numbers were read that way"))
  r <- dd_typed_columns(d, sn$decimal, base)
  list(data = r$data, notes = c(notes, r$notes))
}

DD_MISSING_TOKENS <- c("", "NA", "N/A", "NaN", "nan", "null", "NULL", ".")

dd_typed_columns <- function(d, decimal = ".", base = "") {
  kept <- character(0)
  natok <- character(0)
  for (j in seq_along(d)) {
    s <- d[[j]]
    t <- trimws(s)
    ne <- !t %in% DD_MISSING_TOKENS
    if (!any(ne)) next
    u <- if (decimal == ",") gsub(",", ".", t, fixed = TRUE) else t
    y <- suppressWarnings(as.numeric(ifelse(ne, u, NA)))
    y[!is.finite(y)] <- NA
    allnum <- all(!is.na(y[ne]))
    lead0 <- any(grepl("^-?0[0-9]", t[ne]))
    if (allnum && !lead0) {
      y[ne] <- dd_exact_double(u[ne], y[ne])
      d[[j]] <- y
      if (any(!ne & nzchar(t))) natok <- c(natok, names(d)[j])
    } else if (lead0 && allnum) kept <- c(kept, names(d)[j])
  }
  n <- character(0)
  if (length(kept)) n <- c(n, paste0(base, ": ", paste(kept, collapse = ", "),
                                     " kept as text because values start with 0 (for example ZIP codes or IDs)"))
  if (length(natok)) n <- c(n, paste0(base, ": NA, N/A, NaN, null, or . read as missing in the numeric column(s) ",
                                      paste(natok, collapse = ", ")))
  list(data = d, notes = n)
}
