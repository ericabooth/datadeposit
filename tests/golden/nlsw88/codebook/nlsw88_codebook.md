# Codebook: nlsw88

NLSW, 1988 extract

| Item | Value |
|---|---|
| n_obs | 2246 |
| n_vars | 17 |
| sortedby | idcode |
| question_char |  |
| source_file | nlsw88.dta |

## Dataset notes and characteristics

**Notes:**

1. 1988 data, extracted from National Longitudinal of Young Woman who were ages 14-24 in 1968 (NLSW).
2. This dataset is the result of extraction and processing by various people at various times.
3. For more information on the NLS, see http://www.bls.gov/nls/.

**Characteristics:**

- _lang_c: default
- _lang_list: default

## Variables

| # | Name | Label | Type | Value labels |
|---|---|---|---|---|
| 1 | idcode | NLS ID | int |  |
| 2 | age | Age in current year | byte |  |
| 3 | race | Race | byte | racelbl |
| 4 | married | Married | byte | marlbl |
| 5 | never_married | Never married | byte | nev_mar |
| 6 | grade | Current grade completed | byte |  |
| 7 | collgrad | College graduate | byte | gradlbl |
| 8 | south | Lives in the south | byte | southlbl |
| 9 | smsa | Lives in SMSA | byte | smsalbl |
| 10 | c_city | Lives in a central city | byte | ccitylbl |
| 11 | industry | Industry | byte | indlbl |
| 12 | occupation | Occupation | byte | occlbl |
| 13 | union | Union worker | byte | unionlbl |
| 14 | wage | Hourly wage | float |  |
| 15 | hours | Usual hours worked | byte |  |
| 16 | ttl_exp | Total work experience (years) | float |  |
| 17 | tenure | Job tenure (years) | float |  |

### idcode

**Label:** NLS ID

**Type:** int (numeric), format %8.0g

**Values:** 2246 valid, 0 missing; min 1, max 5159, mean 2612.654497, sd 1480.863763

### age

**Label:** Age in current year

**Type:** byte (numeric), format %8.0g

**Values:** 2246 valid, 0 missing; min 34, max 46, mean 39.15316118, sd 3.060002224

### race

**Label:** Race

**Type:** byte (numeric), format %8.0g

**Values:** 2246 valid, 0 missing; min 1, max 3, mean 1.282724844, sd 0.4754412902

**Value labels** (racelbl):

| Value | Label | Count |
|---|---|---|
| 1 | White | 1637 |
| 2 | Black | 583 |
| 3 | Other | 26 |

### married

**Label:** Married

**Type:** byte (numeric), format %8.0g

**Values:** 2246 valid, 0 missing; min 0, max 1, mean 0.642030276, sd 0.4795099308

**Value labels** (marlbl):

| Value | Label | Count |
|---|---|---|
| 0 | Single | 804 |
| 1 | Married | 1442 |

### never_married

**Label:** Never married

**Type:** byte (numeric), format %16.0g

**Values:** 2246 valid, 0 missing; min 0, max 1, mean 0.1041852182, sd 0.3055687012

**Value labels** (nev_mar):

| Value | Label | Count |
|---|---|---|
| 0 | Has been married | 2012 |
| 1 | Never married | 234 |

### grade

**Label:** Current grade completed

**Type:** byte (numeric), format %8.0g

**Values:** 2244 valid, 2 missing; min 0, max 18, mean 13.09893048, sd 2.521246095

### collgrad

**Label:** College graduate

**Type:** byte (numeric), format %16.0g

**Values:** 2246 valid, 0 missing; min 0, max 1, mean 0.2368655387, sd 0.4252537738

**Value labels** (gradlbl):

| Value | Label | Count |
|---|---|---|
| 0 | Not college grad | 1714 |
| 1 | College grad | 532 |

### south

**Label:** Lives in the south

**Type:** byte (numeric), format %9.0g

**Values:** 2246 valid, 0 missing; min 0, max 1, mean 0.4194122885, sd 0.4935727773

**Value labels** (southlbl):

| Value | Label | Count |
|---|---|---|
| 0 | Not south | 1304 |
| 1 | South | 942 |

### smsa

**Label:** Lives in SMSA

**Type:** byte (numeric), format %9.0g

**Values:** 2246 valid, 0 missing; min 0, max 1, mean 0.7039180766, sd 0.4566292307

**Value labels** (smsalbl):

| Value | Label | Count |
|---|---|---|
| 0 | Not SMSA | 665 |
| 1 | SMSA | 1581 |

### c_city

**Label:** Lives in a central city

**Type:** byte (numeric), format %16.0g

**Values:** 2246 valid, 0 missing; min 0, max 1, mean 0.2916295637, sd 0.45461388

**Value labels** (ccitylbl):

| Value | Label | Count |
|---|---|---|
| 0 | Not central city | 1591 |
| 1 | Central city | 655 |

### industry

**Label:** Industry

**Type:** byte (numeric), format %23.0g

**Values:** 2232 valid, 14 missing; min 1, max 12, mean 8.189516129, sd 3.010874857

**Value labels** (indlbl):

| Value | Label | Count |
|---|---|---|
| 1 | Ag/Forestry/Fisheries | 17 |
| 2 | Mining | 4 |
| 3 | Construction | 29 |
| 4 | Manufacturing | 367 |
| 5 | Transport/Comm/Utility | 90 |
| 6 | Wholesale/Retail trade | 333 |
| 7 | Finance/Ins/Real estate | 192 |
| 8 | Business/Repair svc | 86 |
| 9 | Personal services | 97 |
| 10 | Entertainment/Rec svc | 17 |
| 11 | Professional services | 824 |
| 12 | Public administration | 176 |
| . |  | 14 |

### occupation

**Label:** Occupation

**Type:** byte (numeric), format %22.0g

**Values:** 2237 valid, 9 missing; min 1, max 13, mean 4.642825212, sd 3.408897213

**Value labels** (occlbl):

| Value | Label | Count |
|---|---|---|
| 1 | Professional/Technical | 317 |
| 2 | Managers/Admin | 264 |
| 3 | Sales | 726 |
| 4 | Clerical/Unskilled | 102 |
| 5 | Craftsmen | 53 |
| 6 | Operatives | 246 |
| 7 | Transport | 28 |
| 8 | Laborers | 286 |
| 9 | Farmers | 1 |
| 10 | Farm laborers | 9 |
| 11 | Service | 16 |
| 12 | Household workers | 2 |
| 13 | Other | 187 |
| . |  | 9 |

### union

**Label:** Union worker

**Type:** byte (numeric), format %8.0g

**Values:** 1878 valid, 368 missing; min 0, max 1, mean 0.2454739084, sd 0.4304824567

**Value labels** (unionlbl):

| Value | Label | Count |
|---|---|---|
| 0 | Nonunion | 1417 |
| 1 | Union | 461 |
| . |  | 368 |

### wage

**Label:** Hourly wage

**Type:** float (numeric), format %9.0g

**Values:** 2246 valid, 0 missing; min 1.004951835, max 40.74658966, mean 7.766949037, sd 5.755522859

### hours

**Label:** Usual hours worked

**Type:** byte (numeric), format %8.0g

**Values:** 2242 valid, 4 missing; min 1, max 80, mean 37.21810883, sd 10.50913512

### ttl_exp

**Label:** Total work experience (years)

**Type:** float (numeric), format %9.0g

**Values:** 2246 valid, 0 missing; min 0.115384616, max 28.88461494, mean 12.53497671, sd 4.610207534

### tenure

**Label:** Job tenure (years)

**Type:** float (numeric), format %9.0g

**Values:** 2231 valid, 15 missing; min 0, max 25.91666603, mean 5.977849999, sd 5.510331212

