# Tagged NAs in base R, in the layout haven uses (the tag letter is the fifth
# byte of the NA), so extended missing codes work with or without haven.

dd_tag_na <- function(tags) {
  if (!length(tags)) return(numeric(0))
  b <- rep(as.raw(c(0xa2, 0x07, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x7f)), length(tags))
  b[seq(5, by = 8, length.out = length(tags))] <- charToRaw(paste(tags, collapse = ""))
  readBin(b, "double", n = length(tags), size = 8, endian = "little")
}

# "" for values and ordinary NAs, the letter for tagged NAs
dd_na_tag <- function(x) {
  out <- rep("", length(x))
  if (!is.double(x)) return(out)
  x <- as.double(unclass(x))
  w <- which(is.na(x))
  if (!length(w)) return(out)
  b <- matrix(writeBin(x[w], raw(), size = 8, endian = "little"), nrow = 8)
  tg <- as.integer(b[5, ])
  ok <- tg >= 97L & tg <= 122L
  out[w[ok]] <- rawToChar(b[5, ok], multiple = TRUE)
  out
}
