# Read and write Stata .dta files (formats 117, 118, 119) with full metadata.
#
# haven reads the values of a .dta file but not its characteristics (where
# survey item text usually lives), notes, the names of shared value label
# sets, or label languages. These functions read and write all of it,
# following Stata's published description of the format (help dta). Writing
# always produces format 118, which Stata 14 and later read.

T_DOUBLE <- 65526L; T_FLOAT <- 65527L; T_LONG <- 65528L; T_INT <- 65529L; T_BYTE <- 65530L
T_STRL <- 32768L
MISS_INT <- c(byte = 101, int = 32741, long = 2147483621)
MAX_INT <- c(byte = 100, int = 32740, long = 2147483620)

dd_type_name <- function(code) {
  switch(as.character(code), "65526" = "double", "65527" = "float", "65528" = "long",
         "65529" = "int", "65530" = "byte", "32768" = "strL", paste0("str", code))
}

dd_type_code <- function(name) {
  switch(name, double = T_DOUBLE, float = T_FLOAT, long = T_LONG, int = T_INT, byte = T_BYTE,
         strL = T_STRL, as.integer(sub("^str", "", name)))
}

dd_type_width <- function(code) {
  ifelse(code <= 2045L, code, ifelse(code == T_STRL | code == T_DOUBLE, 8L,
         ifelse(code == T_FLOAT | code == T_LONG, 4L, ifelse(code == T_INT, 2L, 1L))))
}

dd_cstr <- function(r) {
  i <- which(r == as.raw(0))
  if (length(i)) r <- r[seq_len(i[1] - 1L)]
  s <- rawToChar(r)
  Encoding(s) <- "UTF-8"
  s
}

dd_find <- function(buf, pat, from = 1L) {
  p <- charToRaw(pat)
  n <- length(p)
  cand <- which(buf[from:length(buf)] == p[1]) + from - 1L
  for (i in cand) if (identical(buf[i:(i + n - 1L)], p)) return(i)
  stop("datadeposit: ", pat, " not found in the .dta file", call. = FALSE)
}

# Read the header and every metadata section; data only when data = TRUE.
dd_read_dta <- function(path, data = TRUE) {
  con <- file(path, "rb")
  on.exit(close(con))
  head <- readBin(con, "raw", 4096)
  if (!identical(head[1:11], charToRaw("<stata_dta>"))) {
    stop("datadeposit: ", path, " is not a Stata 13+ (format 117+) .dta file", call. = FALSE)
  }
  rel <- as.integer(rawToChar(head[(dd_find(head, "<release>") + 9L):(dd_find(head, "</release>") - 1L)]))
  if (!rel %in% c(117L, 118L, 119L)) stop("datadeposit: dta format ", rel, " is not supported", call. = FALSE)
  e <- if (rawToChar(head[(dd_find(head, "<byteorder>") + 11L):(dd_find(head, "<byteorder>") + 13L)]) == "LSF")
    "little" else "big"
  p <- dd_find(head, "<K>") + 3L
  K <- if (rel == 119L) readBin(head[p:(p + 3L)], "integer", size = 4, endian = e) else
    readBin(head[p:(p + 1L)], "integer", size = 2, signed = FALSE, endian = e)
  p <- dd_find(head, "<N>") + 3L
  N <- if (rel == 117L) readBin(head[p:(p + 3L)], "integer", size = 4, endian = e) else {
    lo <- readBin(head[p:(p + 3L)], "integer", size = 4, endian = e)
    hi <- readBin(head[(p + 4L):(p + 7L)], "integer", size = 4, endian = e)
    if (e == "big") { t <- lo; lo <- hi; hi <- t }
    (if (lo < 0) lo + 2^32 else lo) + hi * 2^32
  }
  p <- dd_find(head, "<label>") + 7L
  if (rel == 117L) { ln <- as.integer(head[p]); p <- p + 1L } else {
    ln <- readBin(head[p:(p + 1L)], "integer", size = 2, signed = FALSE, endian = e); p <- p + 2L }
  label <- if (ln) dd_cstr(c(head[p:(p + ln - 1L)], as.raw(0))) else ""
  p <- dd_find(head, "<map>") + 5L
  map <- vapply(0:13, function(i) {
    lo <- readBin(head[(p + 8L * i):(p + 8L * i + 3L)], "integer", size = 4, endian = e)
    hi <- readBin(head[(p + 8L * i + 4L):(p + 8L * i + 7L)], "integer", size = 4, endian = e)
    if (e == "big") { t <- lo; lo <- hi; hi <- t }
    (if (lo < 0) lo + 2^32 else lo) + hi * 2^32
  }, numeric(1))
  section <- function(i, skip, n) {
    seek(con, map[i + 1L] + skip)
    readBin(con, "raw", n)
  }
  nlen <- if (rel == 117L) 33L else 129L
  types <- readBin(section(2, 16, 2 * K), "integer", n = K, size = 2, signed = FALSE, endian = e)
  r <- section(3, 10, nlen * K)
  names <- vapply(seq_len(K), function(i) dd_cstr(r[((i - 1L) * nlen + 1L):(i * nlen)]), "")
  sw <- if (rel == 119L) 4L else 2L
  sl <- readBin(section(4, 10, sw * (K + 1L)), "integer", n = K + 1L, size = sw, signed = sw == 4L, endian = e)
  sortlist <- character(0)
  for (s in sl) { if (s == 0) break; sortlist <- c(sortlist, names[s]) }
  flen <- if (rel == 117L) 49L else 57L
  r <- section(5, 9, flen * K)
  formats <- vapply(seq_len(K), function(i) dd_cstr(r[((i - 1L) * flen + 1L):(i * flen)]), "")
  r <- section(6, 19, nlen * K)
  vlnames <- vapply(seq_len(K), function(i) dd_cstr(r[((i - 1L) * nlen + 1L):(i * nlen)]), "")
  llen <- if (rel == 117L) 81L else 321L
  r <- section(7, 17, llen * K)
  varlabels <- vapply(seq_len(K), function(i) dd_cstr(r[((i - 1L) * llen + 1L):(i * llen)]), "")
  # characteristics
  r <- section(8, 17, map[10] - map[9] - 17)
  cv <- cn <- ct <- character(0)
  q <- 1L
  while (q + 3L <= length(r) && identical(r[q:(q + 3L)], charToRaw("<ch>"))) {
    ln <- readBin(r[(q + 4L):(q + 7L)], "integer", size = 4, endian = e)
    body <- r[(q + 8L):(q + 7L + ln)]
    cv <- c(cv, dd_cstr(body[1:nlen]))
    cn <- c(cn, dd_cstr(body[(nlen + 1L):(2L * nlen)]))
    ct <- c(ct, dd_cstr(body[(2L * nlen + 1L):ln]))
    q <- q + 8L + ln + 5L
  }
  chars <- data.frame(variable = cv, char = cn, text = ct, stringsAsFactors = FALSE)
  # value labels
  r <- section(11, 14, map[13] - map[12] - 14)
  vls <- list()
  q <- 1L
  while (q + 4L <= length(r) && identical(r[q:(q + 4L)], charToRaw("<lbl>"))) {
    ln <- readBin(r[(q + 5L):(q + 8L)], "integer", size = 4, endian = e)
    nm <- dd_cstr(r[(q + 9L):(q + 8L + nlen)])
    t0 <- q + 9L + nlen + 3L
    n <- readBin(r[t0:(t0 + 3L)], "integer", size = 4, endian = e)
    tl <- readBin(r[(t0 + 4L):(t0 + 7L)], "integer", size = 4, endian = e)
    offs <- if (n) readBin(r[(t0 + 8L):(t0 + 7L + 4L * n)], "integer", n = n, size = 4, endian = e) else integer(0)
    vals <- if (n) readBin(r[(t0 + 8L + 4L * n):(t0 + 7L + 8L * n)], "integer", n = n, size = 4, endian = e) else integer(0)
    txt <- r[(t0 + 8L + 8L * n):(t0 + 7L + 8L * n + tl)]
    labs <- vapply(offs, function(o) dd_cstr(txt[(o + 1L):length(txt)]), "")
    v <- ifelse(vals > MAX_INT[["long"]], paste0(".", letters[pmax(1, vals - MISS_INT[["long"]])]), as.character(vals))
    vls[[nm]] <- data.frame(value = v, label = labs, stringsAsFactors = FALSE)
    q <- q + 9L + nlen + 3L + ln + 6L
  }
  out <- list(release = rel, K = K, N = N, label = label, types = types, names = names, sortlist = sortlist,
              formats = formats, vlnames = vlnames, varlabels = varlabels, chars = chars, value_labels = vls,
              row_width = sum(dd_type_width(types)))
  if (data) {
    seek(con, map[10] + 6)
    W <- out$row_width
    raw <- readBin(con, "raw", N * W)
    out$data <- dd_decode_rows(raw, types, N, e, rel, con, map)
  }
  out
}

dd_decode_rows <- function(raw, types, N, e, rel, con, map) {
  W <- sum(dd_type_width(types))
  m <- if (N) matrix(raw, nrow = W) else matrix(raw(0), nrow = W, ncol = 0)
  start <- cumsum(c(1L, dd_type_width(types)))[seq_along(types)]
  strls <- if (any(types == T_STRL)) dd_read_strls(con, map, e, rel) else NULL
  vals <- vector("list", length(types))
  ext <- vector("list", length(types))
  for (i in seq_along(types)) {
    t <- types[i]
    w <- dd_type_width(t)
    sub <- m[start[i]:(start[i] + w - 1L), , drop = FALSE]
    if (t <= 2045L) {
      vals[[i]] <- if (N) apply(sub, 2, dd_cstr) else character(0)
    } else if (t == T_STRL) {
      if (e == "little") {
        v <- readBin(as.vector(sub[1:2, , drop = FALSE]), "integer", n = N, size = 2, signed = FALSE, endian = e)
        olo <- readBin(as.vector(sub[3:6, , drop = FALSE]), "integer", n = N, size = 4, endian = e)
        ohi <- readBin(as.vector(sub[7:8, , drop = FALSE]), "integer", n = N, size = 2, signed = FALSE, endian = e)
        o <- ifelse(olo < 0, olo + 2^32, olo) + ohi * 2^32
      } else {
        stop("datadeposit: big-endian strL data are not supported", call. = FALSE)
      }
      key <- paste(v, o)
      s <- strls[key]
      s[is.na(s)] <- ""
      vals[[i]] <- unname(s)
    } else if (t %in% c(T_BYTE, T_INT, T_LONG)) {
      tn <- dd_type_name(t)
      x <- readBin(as.vector(sub), "integer", n = N, size = w, signed = TRUE, endian = e)
      miss <- x > MAX_INT[[tn]]
      k <- ifelse(miss, x - MISS_INT[[tn]], 0L)
      x <- as.double(x)
      x[miss] <- NA_real_
      vals[[i]] <- x
      if (any(k > 0)) ext[[i]] <- as.integer(k)
    } else if (t == T_FLOAT) {
      bits <- readBin(as.vector(sub), "integer", n = N, size = 4, endian = e)
      x <- readBin(as.vector(sub), "double", n = N, size = 4, endian = e)
      miss <- !is.na(bits) & bits >= 0x7f000000
      k <- ifelse(miss, (bits - 0x7f000000) %/% 2048L, 0L)
      x[miss] <- NA_real_
      vals[[i]] <- x
      if (any(k > 0)) ext[[i]] <- as.integer(k)
    } else {
      hw <- if (e == "little") 5:8 else 1:4
      high <- readBin(as.vector(sub[hw, , drop = FALSE]), "integer", n = N, size = 4, endian = e)
      x <- readBin(as.vector(sub), "double", n = N, size = 8, endian = e)
      miss <- !is.na(high) & high >= 0x7fe00000
      k <- ifelse(miss, (high - 0x7fe00000) %/% 256L, 0L)
      x[miss] <- NA_real_
      vals[[i]] <- x
      if (any(k > 0)) ext[[i]] <- as.integer(k)
    }
  }
  list(values = vals, ext = ext)
}

dd_read_strls <- function(con, map, e, rel) {
  seek(con, map[11] + 7)
  r <- readBin(con, "raw", map[12] - map[11] - 7)
  out <- character(0)
  q <- 1L
  olen <- if (rel == 117L) 4L else 8L
  while (q + 2L <= length(r) && identical(r[q:(q + 2L)], charToRaw("GSO"))) {
    v <- readBin(r[(q + 3L):(q + 6L)], "integer", size = 4, endian = e)
    olo <- readBin(r[(q + 7L):(q + 10L)], "integer", size = 4, endian = e)
    o <- if (olen == 8L) ifelse(olo < 0, olo + 2^32, olo) +
      readBin(r[(q + 11L):(q + 14L)], "integer", size = 4, endian = e) * 2^32 else olo
    t0 <- q + 7L + olen
    tp <- as.integer(r[t0])
    ln <- readBin(r[(t0 + 1L):(t0 + 4L)], "integer", size = 4, endian = e)
    body <- if (ln) r[(t0 + 5L):(t0 + 4L + ln)] else raw(0)
    if (tp == 130L && length(body) && body[length(body)] == as.raw(0)) body <- body[-length(body)]
    s <- rawToChar(body)
    Encoding(s) <- "UTF-8"
    out[paste(v, o)] <- s
    q <- t0 + 5L + ln
  }
  out
}

# ---- writing ---------------------------------------------------------------

dd_fixed <- function(s, n) {
  b <- charToRaw(enc2utf8(s))
  b <- b[seq_len(min(length(b), n - 1L))]
  c(b, raw(n - length(b)))
}

dd_u64 <- function(x) {
  lo <- x %% 2^32
  hi <- x %/% 2^32
  c(writeBin(as.integer(ifelse(lo >= 2^31, lo - 2^32, lo)), raw(), size = 4, endian = "little"),
    writeBin(as.integer(hi), raw(), size = 4, endian = "little"))
}

dd_write_dta <- function(path, tab) {
  cols <- tab$columns
  K <- length(cols)
  N <- tab$nobs
  types <- vapply(cols, function(c) dd_type_code(c$stata_type), integer(1))
  out <- list()
  add <- function(x) out[[length(out) + 1L]] <<- x
  pos <- function() sum(vapply(out, length, numeric(1)))
  lab <- charToRaw(enc2utf8(tab$label))
  lab <- lab[seq_len(min(length(lab), 320L))]
  add(charToRaw("<stata_dta><header><release>118</release><byteorder>LSF</byteorder><K>"))
  add(writeBin(K, raw(), size = 2, endian = "little"))
  add(charToRaw("</K><N>")); add(dd_u64(N)); add(charToRaw("</N><label>"))
  add(writeBin(length(lab), raw(), size = 2, endian = "little")); add(lab)
  add(charToRaw("</label><timestamp>")); add(as.raw(0)); add(charToRaw("</timestamp></header>"))
  offs <- numeric(14)
  offs[2] <- pos()
  add(charToRaw("<map>")); mapi <- length(out) + 1L; add(raw(112)); add(charToRaw("</map>"))
  sect <- function(i, payload) { offs[i + 1L] <<- pos(); add(payload) }
  sect(2, c(charToRaw("<variable_types>"), writeBin(types, raw(), size = 2, endian = "little"), charToRaw("</variable_types>")))
  sn <- vapply(cols, `[[`, "", "stata_name")
  sect(3, c(charToRaw("<varnames>"), unlist(lapply(sn, dd_fixed, 129L)), charToRaw("</varnames>")))
  sl <- c(match(intersect(tab$sortedby, sn), sn), 0L)
  sl <- c(sl, integer(K + 1L - length(sl)))[seq_len(K + 1L)]
  sect(4, c(charToRaw("<sortlist>"), writeBin(as.integer(sl), raw(), size = 2, endian = "little"), charToRaw("</sortlist>")))
  sect(5, c(charToRaw("<formats>"), unlist(lapply(cols, function(c) dd_fixed(c$format, 57L))), charToRaw("</formats>")))
  sect(6, c(charToRaw("<value_label_names>"), unlist(lapply(cols, function(c) dd_fixed(c$value_labels, 129L))),
            charToRaw("</value_label_names>")))
  sect(7, c(charToRaw("<variable_labels>"), unlist(lapply(cols, function(c) dd_fixed(substr(c$label, 1, 80), 321L))),
            charToRaw("</variable_labels>")))
  chs <- dd_stata_chars(tab)
  chraw <- list(charToRaw("<characteristics>"))
  for (i in seq_len(nrow(chs))) {
    body <- c(dd_fixed(chs$variable[i], 129L), dd_fixed(chs$char[i], 129L), charToRaw(enc2utf8(chs$text[i])), as.raw(0))
    chraw[[length(chraw) + 1L]] <- c(charToRaw("<ch>"), writeBin(length(body), raw(), size = 4, endian = "little"),
                                    body, charToRaw("</ch>"))
  }
  chraw[[length(chraw) + 1L]] <- charToRaw("</characteristics>")
  sect(8, unlist(chraw))
  # data rows
  W <- sum(dd_type_width(types))
  m <- matrix(as.raw(0), nrow = W, ncol = N)
  start <- cumsum(c(1L, dd_type_width(types)))[seq_len(K)]
  gso <- list()
  for (i in seq_len(K)) {
    c <- cols[[i]]
    t <- types[i]
    w <- dd_type_width(t)
    rows <- start[i]:(start[i] + w - 1L)
    if (!N) next
    if (t <= 2045L) {
      m[rows, ] <- vapply(c$values, function(s) dd_fixed(s, w + 1L)[seq_len(w)], raw(w))
    } else if (t == T_STRL) {
      vo <- matrix(as.raw(0), nrow = 8, ncol = N)
      for (r in seq_len(N)) {
        s <- c$values[r]
        if (!nzchar(s)) next
        vo[1:2, r] <- writeBin(i, raw(), size = 2, endian = "little")
        vo[3:8, r] <- dd_u64(r)[1:6]
        body <- c(charToRaw(enc2utf8(s)), as.raw(0))
        gso[[length(gso) + 1L]] <- c(charToRaw("GSO"), writeBin(i, raw(), size = 4, endian = "little"), dd_u64(r),
                                     as.raw(130), writeBin(length(body), raw(), size = 4, endian = "little"), body)
      }
      m[rows, ] <- vo
    } else {
      x <- c$values
      k <- if (is.null(c$ext)) integer(N) else c$ext
      miss <- is.na(x)
      if (t %in% c(T_BYTE, T_INT, T_LONG)) {
        tn <- dd_type_name(t)
        code <- ifelse(miss, MISS_INT[[tn]] + k, x)
        m[rows, ] <- writeBin(as.integer(code), raw(), size = w, endian = "little")
      } else if (t == T_FLOAT) {
        bytes <- matrix(writeBin(ifelse(miss, 0, x), raw(), size = 4, endian = "little"), nrow = 4)
        if (any(miss)) bytes[, miss] <- writeBin(as.integer(0x7f000000 + 2048L * k[miss]), raw(), size = 4, endian = "little")
        m[rows, ] <- bytes
      } else {
        bytes <- matrix(writeBin(ifelse(miss, 0, x), raw(), size = 8, endian = "little"), nrow = 8)
        if (any(miss)) {
          bytes[1:4, miss] <- as.raw(0)
          bytes[5:8, miss] <- writeBin(as.integer(0x7fe00000 + 256L * k[miss]), raw(), size = 4, endian = "little")
        }
        m[rows, ] <- bytes
      }
    }
  }
  sect(9, c(charToRaw("<data>"), as.vector(m), charToRaw("</data>")))
  sect(10, c(charToRaw("<strls>"), unlist(gso), charToRaw("</strls>")))
  vl <- list(charToRaw("<value_labels>"))
  for (nm in names(tab$value_label_sets)) {
    s <- tab$value_label_sets[[nm]]
    txt <- lapply(s$label, function(l) c(charToRaw(enc2utf8(l)), as.raw(0)))
    lens <- vapply(txt, length, integer(1))
    offv <- c(0L, cumsum(lens))[seq_along(lens)]
    val <- ifelse(grepl("^\\.", s$value), MISS_INT[["long"]] + match(substr(s$value, 2, 2), letters),
                  suppressWarnings(as.numeric(s$value)))
    body <- c(writeBin(c(nrow(s), sum(lens)), raw(), size = 4, endian = "little"),
              writeBin(as.integer(offv), raw(), size = 4, endian = "little"),
              writeBin(as.integer(val), raw(), size = 4, endian = "little"), unlist(txt))
    vl[[length(vl) + 1L]] <- c(charToRaw("<lbl>"), writeBin(length(body), raw(), size = 4, endian = "little"),
                               dd_fixed(nm, 129L), raw(3), body, charToRaw("</lbl>"))
  }
  vl[[length(vl) + 1L]] <- charToRaw("</value_labels>")
  sect(11, unlist(vl))
  offs[13] <- pos()
  add(charToRaw("</stata_dta>"))
  offs[14] <- pos()
  out[[mapi]] <- unlist(lapply(offs, dd_u64))
  con <- file(path, "wb")
  on.exit(close(con))
  for (x in out) writeBin(x, con)
  invisible(path)
}
