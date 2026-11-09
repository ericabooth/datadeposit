# Rebuild every golden deposit in R and compare it with Stata's (spec section 7).
# Run from the repository root: Rscript tests/parity/parity.R [python]
library(datadeposit)
args <- commandArgs(trailingOnly = TRUE)
py <- if (length(args)) args[1] else "python3"
bad <- 0
for (ds in c("survey_edge", "auto", "nlsw88")) {
  out <- file.path("tests", "out", "parity_r", ds)
  suppressMessages(datadeposit(file.path("tests", "fixtures", paste0(ds, ".dta")), to = out, replace = TRUE,
                               title = paste("Parity fixture", ds), authors = "Eric A. Booth", license = "CC-BY-4.0"))
  rc <- system2(py, c("tests/parity/compare_deposits.py", file.path("tests", "golden", ds), out))
  if (rc != 0) bad <- bad + 1
}
quit(status = if (bad) 1 else 0)
