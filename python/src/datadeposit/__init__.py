"""datadeposit: archive-ready data deposits that open the same way in Stata, R, Python, and Excel.

    from datadeposit import datadeposit, deposit_use, deposit_verify, deposit_apply
    datadeposit(df, to="survey_deposit", title="Spring survey")
    datadeposit("survey.dta")                      # reads every label, note, and characteristic
    df = deposit_use("survey_deposit")             # labels in df.attrs
    deposit_verify("survey_deposit")

The same command exists in Stata (datadeposit) and R (datadeposit()), and all
three write the same folder. See https://github.com/ericabooth/datadeposit.
"""

from .api import (DepositError, datadeposit, deposit_apply, deposit_codebook, deposit_use, deposit_verify,
                  find_rscript)

PACKAGE_VERSION = "0.1.0"
__version__ = PACKAGE_VERSION
deposit = datadeposit

__all__ = ["datadeposit", "deposit", "deposit_use", "deposit_verify", "deposit_apply", "deposit_codebook",
           "DepositError", "find_rscript", "__version__"]
