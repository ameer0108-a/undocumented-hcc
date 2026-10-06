# Data dictionary

Four schemas in one PostgreSQL database.

## ehr: normalized synthetic EHR

| Table | Grain | Key columns |
|---|---|---|
| `concept` | one row per code | `concept_id`, `vocabulary` (SNOMED, LOINC, RXNORM, CVX), `code`, `description` |
| `patient` | one row per person | `patient_id`, `person_uuid` (Synthea Id), `batch`, `birth_date`, `death_date`, `sex`, `race`, `ethnicity`, `county`, `zip`, `income` |
| `encounter` | one row per visit | `encounter_id`, `patient_id`, `start_ts`, `stop_ts`, `encounter_class` (wellness, ambulatory, outpatient, urgentcare, emergency, inpatient, ...), `concept_id`, `reason_concept_id` |
| `condition` | one row per coded condition | `patient_id`, `encounter_id`, `start_date`, `stop_date`, `concept_id` |
| `observation` | one row per result | `patient_id`, `encounter_id`, `obs_ts`, `category`, `concept_id` (LOINC), `value_num`, `value_text`, `units` |
| `medication` | one row per prescription | `patient_id`, `start_ts`, `stop_ts`, `concept_id` (RxNorm), `reason_concept_id`, `dispenses` |
| `procedure`, `immunization`, `careplan`, `allergy`, `device`, `supply`, `imaging_study` | as named | loaded for completeness and record counts; not used by the rules |
| `organization`, `provider`, `payer` | lookup | shared across batches |
| `load_log` | one row per batch | `batch`, `seed`, `n_patients`, `n_rows` |

Synthea patient names, SSNs, and street addresses are not loaded.

## ref: reference tables

| Table | What it holds |
|---|---|
| `study_params`, `lab_model_params` | copies of the two config CSVs, so SQL and R read the same numbers |
| `snomed_icd10cm` | the hand-built crosswalk (`reference/snomed_icd10cm_crosswalk.csv`) |
| `v28_dx_to_hcc` | CMS 2026 midyear/final ICD-10-CM to V28 HCC map (no dots in codes) |
| `v28_labels`, `v28_hierarchy`, `v28_coefficient` | V28 labels, hierarchy pairs, and community non-dual aged coefficients |
| `lab_loinc` | which LOINC codes count as HbA1c, creatinine, uACR |
| `dm_medication` | ingredient patterns for glucose-lowering drugs |

Functions: `ref.p(key)` reads a study parameter; `ref.egfr_ckd_epi_2021(scr, age, sex)`; `ref.hcc_from_egfr(egfr)`.

## study: analysis tables

| Table | Grain | Notes |
|---|---|---|
| `cohort` | patient | age, sex, `office_days`, `visits_per_year`, `visit_band` |
| `attrition` | step | how the cohort was narrowed |
| `chronic_concept` | SNOMED disorder | concepts where at least half of records never get a stop date |
| `condition_mapped` | condition record | SNOMED, ICD-10-CM, HCC, chronic flag |
| `crosswalk_coverage` | scope | coverage percentages |
| `truth` | patient | `dm_true`, `dm_hcc`, `prediabetes`, `ckd_stage_coded`, `ckd_hcc` (all before masking) |
| `lab_draw` | lab draw | timing, setting (acute or outpatient), Synthea's original value |
| `dm_med` | patient | on a glucose-lowering drug in the window |
| `mask` | patient x family | which true cases were hidden |
| `documented` | patient | documentation status after masking |
| `lab_latent` | patient | the lab model's true HbA1c mean, eGFR, creatinine, and implied HCC |
| `lab_calibration` | scenario x lab | keep probability and achieved annual testing rate |
| `lab_value` | scenario x draw | the values the rules actually read |
| `rule_flag_sql`, `rule_flag_r` | scenario x patient x target HCC | `t1`, `t2`, `t3` flags from each implementation |

## Scenarios in `lab_value`

| Scenario | Values | Missing tests |
|---|---|---|
| `raw` | Synthea's own | none removed |
| `model_complete` | lab model | none removed |
| `calibrated` | lab model | thinned to Medicare testing rates (main analysis) |
| `sens_egfr_sd10` / `sens_egfr_sd20` | lab model with a tighter or wider non-CKD eGFR spread | thinned |
