# Codebook: auto

1978 automobile data

| Item | Value |
|---|---|
| n_obs | 74 |
| n_vars | 12 |
| sortedby | foreign |
| question_char |  |
| source_file | auto.dta |

## Dataset notes and characteristics

**Notes:**

1. From Consumer Reports with permission

**Characteristics:**

- _lang_c: default
- _lang_list: default

## Variables

| # | Name | Label | Type | Value labels |
|---|---|---|---|---|
| 1 | make | Make and model | str18 |  |
| 2 | price | Price | int |  |
| 3 | mpg | Mileage (mpg) | int |  |
| 4 | rep78 | Repair record 1978 | int |  |
| 5 | headroom | Headroom (in.) | float |  |
| 6 | trunk | Trunk space (cu. ft.) | int |  |
| 7 | weight | Weight (lbs.) | int |  |
| 8 | length | Length (in.) | int |  |
| 9 | turn | Turn circle (ft.) | int |  |
| 10 | displacement | Displacement (cu. in.) | int |  |
| 11 | gear_ratio | Gear ratio | float |  |
| 12 | foreign | Car origin | byte | origin |

### make

**Label:** Make and model

**Type:** str18 (string), format %-18s

**Values:** 74 valid, 0 empty

### price

**Label:** Price

**Type:** int (numeric), format %8.0gc

**Values:** 74 valid, 0 missing; min 3291, max 15906, mean 6165.256757, sd 2949.495885

### mpg

**Label:** Mileage (mpg)

**Type:** int (numeric), format %8.0g

**Values:** 74 valid, 0 missing; min 12, max 41, mean 21.2972973, sd 5.78550321

### rep78

**Label:** Repair record 1978

**Type:** int (numeric), format %8.0g

**Values:** 69 valid, 5 missing; min 1, max 5, mean 3.405797101, sd 0.9899322701

### headroom

**Label:** Headroom (in.)

**Type:** float (numeric), format %6.1f

**Values:** 74 valid, 0 missing; min 1.5, max 5, mean 2.993243243, sd 0.8459947668

### trunk

**Label:** Trunk space (cu. ft.)

**Type:** int (numeric), format %8.0g

**Values:** 74 valid, 0 missing; min 5, max 23, mean 13.75675676, sd 4.277404189

### weight

**Label:** Weight (lbs.)

**Type:** int (numeric), format %8.0gc

**Values:** 74 valid, 0 missing; min 1760, max 4840, mean 3019.459459, sd 777.1935671

### length

**Label:** Length (in.)

**Type:** int (numeric), format %8.0g

**Values:** 74 valid, 0 missing; min 142, max 233, mean 187.9324324, sd 22.2663399

### turn

**Label:** Turn circle (ft.)

**Type:** int (numeric), format %8.0g

**Values:** 74 valid, 0 missing; min 31, max 51, mean 39.64864865, sd 4.399353727

### displacement

**Label:** Displacement (cu. in.)

**Type:** int (numeric), format %8.0g

**Values:** 74 valid, 0 missing; min 79, max 425, mean 197.2972973, sd 91.83721896

### gear_ratio

**Label:** Gear ratio

**Type:** float (numeric), format %6.2f

**Values:** 74 valid, 0 missing; min 2.190000057, max 3.890000105, mean 3.014864867, sd 0.4562870967

### foreign

**Label:** Car origin

**Type:** byte (numeric), format %8.0g

**Values:** 74 valid, 0 missing; min 0, max 1, mean 0.2972972973, sd 0.4601884584

**Value labels** (origin):

| Value | Label | Count |
|---|---|---|
| 0 | Domestic | 52 |
| 1 | Foreign | 22 |

