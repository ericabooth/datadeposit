#!/bin/sh
# After pushing, confirm that the README's install lines work from GitHub.
# Each install goes into a throwaway folder, so nothing on this machine changes.
# Run from anywhere:  sh tools/check_github_install.sh
# The git credential helper is switched off for this script: the repository is
# public, so no saved login is needed or read.
set -e
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
T=$(mktemp -d)
cd "$T"
STATA=${STATA:-/Applications/StataNow/StataMP.app/Contents/MacOS/stata-mp}
if [ -x "$STATA" ]; then
  mkdir plus
  cat > i.do <<DO
sysdir set PLUS "$T/plus"
net install datadeposit, from("https://raw.githubusercontent.com/ericabooth/datadeposit/main/") replace force
discard
which datadeposit
sysuse auto, clear
datadeposit, to(auto_deposit)
DO
  "$STATA" -q -b do i.do
  grep -q "round trip (csv + setup.do vs. the data): passed" i.log && echo "Stata install from GitHub: OK"
fi
python3 -m venv v1
v1/bin/python -m pip install -q "git+https://github.com/ericabooth/datadeposit.git#subdirectory=python"
v1/bin/python -c "import datadeposit; print('Python install with git: OK', datadeposit.__version__)"
python3 -m venv v2
v2/bin/python -m pip install -q "https://github.com/ericabooth/datadeposit/archive/refs/heads/main.zip#subdirectory=python"
v2/bin/python -c "import datadeposit; print('Python install from zip: OK', datadeposit.__version__)"
mkdir rlib
Rscript -e 'options(repos = "https://cloud.r-project.org"); if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes"); remotes::install_github("ericabooth/datadeposit", subdir = "r", lib = "rlib", upgrade = "never", quiet = TRUE); library(datadeposit, lib.loc = "rlib"); cat("R install from GitHub: OK", as.character(packageVersion("datadeposit")), "\n")'
echo "all install lines work; scratch folder: $T"
