# testthat battery for the R datadeposit package (mirrors stata/tests/datadeposit_battery.do)

fixture <- function(f) {
  p <- testthat::test_path("fixtures", f)
  if (!file.exists(p)) p <- testthat::test_path("..", "..", "..", "tests", "fixtures", f)
  if (!file.exists(p)) testthat::skip("fixtures not available")
  normalizePath(p)
}

dep <- function(...) suppressMessages(datadeposit(...))

test_that("a full deposit of the survey fixture round-trips", {
  out <- file.path(tempdir(), "r_sv")
  unlink(out, recursive = TRUE)
  r <- dep(fixture("survey_edge.dta"), to = out, title = "Battery survey")
  expect_equal(r$verified, "passed")
  expect_equal(r$profile, "full")
  for (f in c("README.md", "MANIFEST.json", "datapackage.json", "data/survey_edge.csv", "data/survey_edge.dta",
              "data/survey_edge.rds", "metadata/survey_edge_chars.csv", "codebook/survey_edge_ddi.xml",
              "setup/survey_edge_setup.R")) {
    expect_true(file.exists(file.path(out, f)), info = f)
  }
})

test_that("item text, notes, label languages, and extended missing survive", {
  fixture("survey_edge.dta")
  out <- file.path(tempdir(), "r_sv")
  d <- deposit_use(out)
  src <- datadeposit:::dd_read_dta(fixture("survey_edge.dta"), data = FALSE)
  q1 <- src$chars$text[src$chars$variable == "q1" & src$chars$char == "question"]
  expect_identical(attr(d$q1, "question"), q1)
  expect_gt(nchar(attr(d$q2, "question")), 60000)
  expect_identical(attr(d$q1, "notes"), c("Recoded 6 to .r on 2025-01-15.", "Second note on q1"))
  expect_identical(unname(attr(d$q1, "stata_chars")["_lang_v_es"]), "Confianza en el gobierno local")
  expect_equal(sum(haven::na_tag(d$q1) == "d", na.rm = TRUE), 26)
  expect_identical(d$income[1], 0.1 + 0.2)
  expect_identical(d$comment[11], "CRLF\r\ninside")
  rds <- readRDS(file.path(out, "data", "survey_edge.rds"))
  expect_identical(unclass(rds$q3), unclass(d$q3))
})

test_that("the dta reader and writer keep everything", {
  t <- datadeposit:::dd_from_dta(fixture("survey_edge.dta"))
  p <- tempfile(fileext = ".dta")
  datadeposit:::dd_write_dta(p, t)
  u <- datadeposit:::dd_from_dta(p)
  for (i in seq_along(t$columns)) {
    a <- t$columns[[i]]; b <- u$columns[[i]]
    expect_identical(a[c("name", "stata_type", "format", "label", "value_labels")], b[c("name", "stata_type", "format", "label", "value_labels")])
    expect_identical(a$values, b$values)
  }
  expect_identical(t$value_label_sets, u$value_label_sets)
  h <- haven::read_dta(p)
  expect_identical(as.vector(unclass(h$income)), t$columns[[4]]$values)
})

test_that("verify detects tampering", {
  out <- file.path(tempdir(), "r_tamper")
  unlink(out, recursive = TRUE)
  dep(fixture("survey_edge.dta"), to = out, stats = FALSE)
  expect_true(deposit_verify(out, quiet = TRUE)$ok)
  cat('"extra","row"\n', file = file.path(out, "metadata", "survey_edge_dataset.csv"), append = TRUE)
  expect_false(deposit_verify(out, quiet = TRUE)$ok)
})

test_that("replace only overwrites deposits", {
  out <- file.path(tempdir(), "r_rep")
  unlink(out, recursive = TRUE)
  dep(fixture("auto.dta"), to = out)
  expect_error(dep(fixture("auto.dta"), to = out), "already exists")
  dep(fixture("auto.dta"), to = out, replace = TRUE, stats = FALSE)
  expect_false(file.exists(file.path(out, "metadata", "auto_summary.csv")))
  keep <- file.path(tempdir(), "r_keep")
  dir.create(keep, showWarnings = FALSE)
  writeLines("keep me", file.path(keep, "keep.txt"))
  expect_error(dep(fixture("auto.dta"), to = keep, replace = TRUE), "not a datadeposit folder")
  expect_true(file.exists(file.path(keep, "keep.txt")))
})

test_that("size check, lean, and nodata", {
  b <- file.path(tempdir(), "r_big")
  unlink(c(b, paste0(b, 2), paste0(b, 3)), recursive = TRUE)
  expect_error(dep(fixture("auto.dta"), to = b, max_size_gb = 1e-6), "over the")
  expect_false(dir.exists(b))
  r <- dep(fixture("auto.dta"), to = b, max_size_gb = 1e-6, on_large = "lean")
  expect_equal(r$profile, "lean")
  expect_equal(r$formats, c("csv", "rds"))
  expect_false(file.exists(file.path(b, "data", "auto.dta")))
  r <- dep(fixture("auto.dta"), to = paste0(b, 2), max_size_gb = 1e-6, allow_large = TRUE)
  expect_equal(r$formats, c("csv", "dta", "rds"))
  r <- dep(fixture("auto.dta"), to = paste0(b, 3), nodata = TRUE)
  expect_false(file.exists(file.path(paste0(b, 3), "data", "auto.csv")))
  expect_error(dep(fixture("auto.dta"), to = paste0(b, 4), formats = "dta"), "must include csv")
})

test_that("a data frame deposit, then a new version that records its parent", {
  d0 <- data.frame(id = 1:3, check.names = FALSE)
  d0[["score (pct)"]] <- c(1.5, NA, 3.25)
  d0$grade <- factor(c("A", "B", "A"))
  attr(d0[["score (pct)"]], "label") <- strrep("S", 120)
  out <- file.path(tempdir(), "r_frame")
  unlink(c(out, file.path(tempdir(), "frame_deposit_v2")), recursive = TRUE)
  r <- dep(d0, to = out, name = "frame")
  expect_equal(r$verified, "passed")
  back <- deposit_use(out)
  expect_identical(names(back), c("id", "score (pct)", "grade"))
  expect_identical(attr(back[["score (pct)"]], "label"), strrep("S", 120))
  back$id <- back$id * 10
  r2 <- dep(back, changes = "ids times ten")
  expect_match(r2$path, "frame_deposit_v2$")
  m <- jsonlite::fromJSON(file.path(r2$path, "MANIFEST.json"))
  expect_equal(m$version, "2")
  expect_equal(m$derived_from$path, normalizePath(out))
})

test_that("apply edited metadata", {
  out <- file.path(tempdir(), "r_cb")
  unlink(out, recursive = TRUE)
  dep(fixture("auto.dta"), to = out, nodata = TRUE)
  p <- file.path(out, "metadata", "auto_variables.csv")
  v <- utils::read.csv(p, colClasses = "character")
  v$label[v$name == "mpg"] <- "Miles per gallon (EPA)"
  v$new_name <- ifelse(v$name == "turn", "turning_circle", "")
  v$drop <- ifelse(v$name == "trunk", "1", "")
  utils::write.csv(v, p, row.names = FALSE)
  d <- haven::read_dta(fixture("auto.dta"))
  new <- suppressMessages(deposit_apply(d, out))
  expect_identical(attr(new$mpg, "label"), "Miles per gallon (EPA)")
  expect_true("turning_circle" %in% names(new))
  expect_false("trunk" %in% names(new))
})

test_that("extended missing codes follow rows, with and without haven", {
  out <- file.path(tempdir(), "r_tags")
  unlink(out, recursive = TRUE)
  dep(fixture("survey_edge.dta"), to = out)
  for (hv in c(TRUE, FALSE)) {
    d <- deposit_use(out, haven = hv)
    expect_equal(sum(datadeposit:::dd_na_tag(d$q1) == "d"), 26)
    expect_identical(sum(haven::na_tag(d$q1) == "r", na.rm = TRUE), 11L)
    want <- c(table(datadeposit:::dd_na_tag(d$q1)[d$wave == 1]))
    sub <- d[d$wave == 1, ]
    sub <- sub[order(sub$income), ]
    out2 <- file.path(tempdir(), "r_tags_sub")
    r <- dep(sub, to = out2, replace = TRUE)
    expect_equal(r$verified, "passed")
    expect_identical(c(table(datadeposit:::dd_na_tag(deposit_use(out2, haven = hv)$q1))), want)
  }
})

test_that("awkward columns are converted with a note, and bad targets are refused", {
  d <- data.frame(x = c(1.5, Inf, NA), stringsAsFactors = FALSE)
  d$lst <- list(1:2, "a", NULL)
  d$span <- as.difftime(c(1, 2, 3), units = "hours")
  d$when <- as.POSIXct("2025-01-01 12:00", tz = "America/Chicago") + 0:2
  d$day <- as.Date("1950-05-06") + 0:2
  out <- file.path(tempdir(), "r_awk")
  unlink(out, recursive = TRUE)
  m <- capture.output(r <- datadeposit(d, to = out, name = "awk"), type = "message")
  expect_equal(r$verified, "passed")
  expect_true(any(grepl("infinite", m)) && any(grepl("list column", m)) && any(grepl("UTC", m)))
  f <- tempfile(fileext = ".txt")
  writeLines("x", f)
  expect_error(dep(d, to = f, replace = TRUE), "is a file")
  expect_error(dep(data.frame(a = 1, a = 2, check.names = FALSE), to = file.path(tempdir(), "r_dup")), "unique")
  expect_error(deposit_use(tempdir()), "not a datadeposit folder")
})

test_that("a wide file stays fast", {
  k <- 1500
  d <- as.data.frame(matrix(rep(1:5, length.out = 50 * k), nrow = 50))
  names(d) <- paste0("q", seq_len(k))
  for (j in seq_len(k)) attr(d[[j]], "label") <- paste("Question", j)
  out <- file.path(tempdir(), "r_wide")
  unlink(out, recursive = TRUE)
  t0 <- Sys.time()
  r <- dep(d, to = out, name = "wide", formats = c("csv", "dta"))
  expect_equal(r$verified, "passed")
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 120)
})
