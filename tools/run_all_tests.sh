#!/bin/sh
# Every test, every language. Run from the repository root on a machine with
# Stata, R, and Python:  sh tools/run_all_tests.sh
# Set STATA to your Stata executable(s); the default checks StataNow and Stata 16.
set -e
PY=${PY:-.venv/bin/python}
STATAS=${STATAS:-"/Applications/StataNow/StataMP.app/Contents/MacOS/stata-mp /Applications/Stata/StataSE_old.app/Contents/MacOS/stata-se"}
$PY tools/sync_templates.py --check
for S in $STATAS; do
  [ -x "$S" ] || continue
  (cd stata/tests && "$S" -q -b do datadeposit_battery.do && grep "^BATTERY PASSED" datadeposit_battery.log)
done
FIRST=$(echo $STATAS | cut -d' ' -f1)
if [ -x "$FIRST" ]; then "$FIRST" -q -b do tests/parity/make_golden.do; fi
$PY -m pytest -q python/tests
(cd r && R CMD INSTALL --no-multiarch . >/dev/null 2>&1 && Rscript -e 'testthat::test_dir("tests/testthat", package = "datadeposit", load_package = "installed", stop_on_failure = TRUE)')
$PY tests/parity/parity.py
Rscript tests/parity/parity.R "$PY"
# torture suite: messy real-world inputs, every language, compared with each other
$PY tests/torture/make_inputs.py
$PY tests/torture/torture_py.py
Rscript tests/torture/torture_R.R
if [ -x "$FIRST" ]; then "$FIRST" -q -b do tests/torture/torture_stata.do && mv torture_stata.log tests/out/; fi
$PY tests/torture/torture_check.py
echo "ALL TESTS PASSED"
