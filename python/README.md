# datadeposit for Python

The Python package of [datadeposit](https://github.com/ericabooth/datadeposit), which
prepares data, documentation, and code for colleagues the way a data archive would. The
repository README explains what a deposit holds and how the Stata, R, and Python
versions fit together.

Install it from a terminal:

```bash
python3 -m pip install "git+https://github.com/ericabooth/datadeposit.git#subdirectory=python"
```

Then use it:

```python
from datadeposit import datadeposit, deposit_use, deposit_verify

datadeposit("survey.dta", to="survey_deposit")     # or a DataFrame, a csv, a folder
df = deposit_use("survey_deposit")                 # labels are in df.attrs
deposit_verify("survey_deposit")
```
