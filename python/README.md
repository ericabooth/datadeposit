# datadeposit for Python

The Python half of [datadeposit](https://github.com/ericabooth/datadeposit). See the
repository README for what it does and how the Stata, R, and Python versions fit together.

```bash
pip install "git+https://github.com/ericabooth/datadeposit.git#subdirectory=python"
```

```python
from datadeposit import datadeposit, deposit_use, deposit_verify
datadeposit("survey.dta", to="survey_deposit")
df = deposit_use("survey_deposit")
```
