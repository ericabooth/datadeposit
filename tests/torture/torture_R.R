# Deposit every torture input from R and record the outcome.
# Run from the repository root:  Rscript tests/torture/torture_R.R
library(datadeposit)
base <- file.path("tests", "out", "torture")
outdir <- file.path(base, "r", "Eric's deposits", enc2utf8("d\u00e9p\u00f4t 2026"))
files <- sort(list.files(file.path(base, "inputs")))
res <- data.frame(file = character(0), outcome = character(0), detail = character(0))
for (f in files) {
  key <- gsub("[. ]", "_", f)
  r <- tryCatch({
    x <- suppressMessages(datadeposit(file.path(base, "inputs", f), to = file.path(outdir, key), replace = TRUE))
    c("ok", x$verified)
  }, error = function(e) c("error", substr(gsub("\n", " ", conditionMessage(e)), 1, 200)))
  res[nrow(res) + 1, ] <- c(f, r)
}
x <- suppressMessages(datadeposit(folder = file.path(base, "inputs"), pattern = "*", to = file.path(outdir, "whole_folder"), replace = TRUE))
res[nrow(res) + 1, ] <- c("(whole folder)", "ok", paste(x$verified, paste(x$datasets, collapse = " ")))
# a deposit that crashed halfway: use refuses it, replace cleans it up
crash <- file.path(outdir, "crashed")
dir.create(file.path(crash, "data"), recursive = TRUE, showWarnings = FALSE)
writeLines('{"datadeposit": "1.0", "status": "incomplete", "files": []}', file.path(crash, "MANIFEST.json"))
writeLines(c("x", "1"), file.path(crash, "data", "stray.csv"))
refused <- tryCatch({ deposit_use(crash); "no" }, error = function(e) "yes")
x <- suppressMessages(datadeposit(file.path("tests", "fixtures", "auto.dta"), to = crash, replace = TRUE))
gone <- if (file.exists(file.path(crash, "data", "stray.csv"))) "no" else "yes"
res[nrow(res) + 1, ] <- c("(crashed folder)", "ok", paste0(x$verified, " use_refused=", refused, " stray_removed=", gone))
utils::write.csv(res, file.path(base, "results_r.csv"), row.names = FALSE)
cat("R:", nrow(res), "cases\n")
