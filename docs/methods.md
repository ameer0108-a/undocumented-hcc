# Methods

This is the long version. The README has the short one.

## 1. Question

Medicare Advantage pays plans more for sicker members, using CMS-HCC risk scores built from diagnosis codes. A condition the patient has but nobody coded this year is missing from that score. Lab results can sometimes show the condition even when the code is missing.

The question here is narrow. For four V28 HCCs, how well do simple lab rules find conditions that are present but not documented? And what does each rule cost in alert volume, false alerts, and missed patients?

| HCC | V28 label | Coefficient (community, non-dual, aged) | Lab signal |
|---|---|---|---|
| 38 | Diabetes with Glycemic, Unspecified, or No Complications | 0.166 | HbA1c |
| 329 | Chronic Kidney Disease, Moderate (Stage 3, Except 3B) | 0.127 | eGFR 45 to 59 |
| 328 | Chronic Kidney Disease, Moderate (Stage 3B) | 0.127 | eGFR 30 to 44 |
| 327 | Chronic Kidney Disease, Severe (Stage 4) | 0.514 | eGFR 15 to 29 |

Stage 5 and ESRD (HCC 326) are left out on purpose. Those patients are almost always on dialysis or transplant lists and are paid under the separate ESRD model.

## 2. Data

**Synthetic EHR.** Synthea (master-branch build d9d07a6, built August 18, 2026), North Carolina demographics, 20 batches of 1,000 living patients requested at ages 65 to 100 (20,000 patients and 55.8 million records in total), with a simulation end date of January 1, 2026 and 10 years of exported history. Batch seeds are 20250001 to 20250020. Each batch is loaded into PostgreSQL 16 and normalized. UUIDs become integer keys, and descriptions move into one concept table. This keeps the full database at a few GB.

**CMS reference files.** The V28 ICD-10-CM to HCC mapping, labels, hierarchies, and coefficients come from the CMS 2026 midyear/final model files. They were extracted from the copy packaged with the open-source `hccinfhir` Python package (v0.4.0) because cms.gov could not be reached from the build machine. Spot checks against published values: N18.32 maps to 328, N18.4 to 327, and HCC 327 = 0.514. These checks are in `tests/testthat/test-crosswalk.R`.

**ICD-10-CM code set.** April 1, 2026 release (via the `simple_icd_10_cm` package). It was used only to confirm that every code in the crosswalk is valid and billable.

**MIMIC-IV Clinical Database Demo v2.2.** 100 real, de-identified hospital patients, open access under the ODbL. It is used only for the real-data check in section 9.

## 3. Cohort

- Age 65 or older on the index date, December 31, 2025.
- Alive on the index date.
- At least one encounter of any kind in the two-year window (January 1, 2024 to December 31, 2025).

The measurement year is 2025. Under V28, 2025 dates of service feed payment year 2026. A condition counts as documented if a code for it is active at any point in 2025.

Visit frequency is the number of distinct days with a wellness, ambulatory, or outpatient encounter in the window, divided by 2. Patients are grouped as 2 or fewer, 3 to 5, and 6 or more office visit days per year.

## 4. Crosswalk: SNOMED CT to ICD-10-CM to V28

Synthea records conditions in SNOMED CT. Payment runs on ICD-10-CM. The NLM SNOMED-to-ICD-10-CM map needs a UMLS license, so every SNOMED disorder Synthea emitted for this population was mapped by hand. Each was mapped to the most specific ICD-10-CM code the SNOMED concept actually supports, and the reason for any non-obvious pick is written in the `map_note` column. A few examples:

- **CKD stage 3 goes to N18.30 (unspecified stage 3).** Synthea never says 3a or 3b.
- **Burns go to T30.0.** ICD-10-CM's degree-specific burn codes need a body region, and Synthea doesn't record one.
- **Mitral and tricuspid stenosis go to rheumatic codes (I05.0, I07.0).** That is ICD-10-CM's default when nothing else is specified.

Every code was checked against the April 2026 code set. Five failed on the first pass (T30.1, T30.2, T30.3, T09.3, T08.XXXA: invalid or not billable in ICD-10-CM) and were replaced. The ICD-10-CM to HCC step then uses the CMS file as is.

**Coverage.** A disorder concept counts as chronic if at least half of its records in the cohort never get a stop date. Coverage is the share of chronic disorder records in the cohort that land on a valid ICD-10-CM code. The share that also lands on a V28 HCC is reported separately.

The first crosswalk was built from the codes in the first three batches. On the full cohort, it covered 99.98% of chronic disorder records: 11 rare chronic concepts only showed up in later batches. After mapping those and 8 rare acute ones, all 186 disorder concepts in the cohort are mapped.

## 5. Ground truth and masking

In Synthea, every condition a patient truly has is also coded. So "truth" is simply the coded state before anything is hidden. The one exception is diabetes. Truth there is the type 2 diabetes diagnosis itself rather than "any code in HCC 36 to 38", for the reason given in section 6, item 4.

To create undocumented conditions with a known answer, a random share of true cases had every code in the condition's HCC family removed. If a diabetic patient is masked, all codes in HCCs 36, 37, and 38 go together, including complication codes like diabetic neuropathy. Otherwise a leftover code would give the diagnosis away.

| Family | Masking rate | Basis |
|---|---|---|
| Diabetes | 27.6% | CDC National Diabetes Statistics Report (data through 2023): 27.6% of adults with diabetes are undiagnosed |
| CKD stage 3 to 4 | 51% | CMS Office of Minority Health Data Highlight No. 20 (2020): only 49% of Medicare Advantage members with lab-identified stage 3 CKD had a CKD code |

Seed: 20251231. Section 8 shows that PPV depends heavily on these rates, so a sweep from 10% to 60% is reported too.

## 6. Why the raw Synthea labs were replaced

The rules were first run on Synthea's own values, and the results did not hold up. Each problem was traced back to the module that generates the value:

1. **HbA1c goes below what a living person can have.** In `metabolic_syndrome_care`, HbA1c is recorded from Synthea's blood glucose value, and the medication effect pushes it down hard. In the year after diagnosis, diabetics average about 6.8%. After that the average is 4.1%, and in the 2024 to 2025 window, 56% of true diabetics' HbA1c results are under 4.0%, and only 6% reach 6.5%.
2. **Creatinine is hard-coded in modules that have nothing to do with the kidney.** `veteran_hyperlipidemia` and `colorectal_cancer` record every metabolic panel with creatinine drawn from 2.5 to 3.5 mg/dL, whatever the patient's kidney status. For an older adult, that is eGFR of roughly 15 to 25, which looks like stage 4 CKD.
3. **Creatinine doesn't match the coded CKD stage.** `kidney_conditions` assigns creatinine by stage, but the ranges aren't tied to any eGFR equation. Patients coded stage 1 or 2 almost always have creatinine that implies stage 3 or worse.
4. **Kidney disease is labeled "due to diabetes" in people without diabetes.** The CKD module runs for patients with hypertension or diabetes, but the kidney conditions it records are named "Disorder of kidney due to diabetes mellitus", "Microalbuminuria due to type 2 diabetes", and "Proteinuria due to type 2 diabetes" either way. Those map to HCC 37, which is in the diabetes family. Half of the cohort patients carrying any diabetes-family code (50.3%) never have a diabetes diagnosis. Because of this, diabetes truth is defined by the type 2 diabetes diagnosis itself (SNOMED 44054006), and these patients are treated as non-diabetic.
5. **Insulin is prescribed for prediabetes.** Synthea writes insulin prescriptions with prediabetes as the reason. In the window, 26.8% of prediabetic patients are on insulin. That is not standard care, and it makes "on a diabetes drug" a much weaker signal than it is in real life. This one was left in the main analysis on purpose, as a stress test for the hybrid rule. A sensitivity analysis removes those prescriptions.

`output/tables/raw_lab_artifacts.csv` puts numbers on each of these. The raw results are still reported as the "Raw Synthea labs" scenario.

## 7. Lab model

Synthea still provides the patients, their true conditions, their visits, and the date, time, and setting of every lab draw. Only the value on each result is replaced. Every parameter is in `config/study_params.csv` or `config/lab_model_params.csv`, along with its source or the reason for the assumption.

**Each patient's stable true level**
- HbA1c for true diabetics: log-normal, median 6.95%, log-SD 0.16. About half end up under 7%, which matches US adults with diagnosed diabetes (Fang et al., NEJM 2021). Prediabetes: uniform 5.7 to 6.4. Everyone else: uniform 4.8 to 5.6.
- True eGFR by coded stage. No CKD 3+ code: 60 plus a half-normal with SD 15, capped at 120. Stage 1: 90 to 110. Stage 2: 60 to 89.9. Stage 3: 3a (45 to 59.9) with probability 0.70, otherwise 3b (30 to 44.9). Stage 4: 15 to 29.9. Stage 5: 5 to 14.9.
- True creatinine is the CKD-EPI 2021 equation run backwards from true eGFR, age, and sex.

**Variation from draw to draw**
- HbA1c: multiplicative log-normal noise. Within-subject CV is 1.7% without diabetes and 8.3% with type 2 diabetes (Gough et al., PLOS ONE 2023). Reported to 1 decimal.
- Creatinine: CV 5.12%, which combines within-subject 5.0% (Thöni et al., 2022 meta-analysis) with 1.1% analytical. Reported to 2 decimals.
- AKI: an inpatient or ED creatinine draw has a 21.6% chance (Susantitaphong et al., CJASN 2013) of being multiplied by 1.5 to 3.0, which spans KDIGO AKI stages 1 to 3.
- uACR is kept as Synthea generates it.

**Missing tests.** Synthea orders labs more often than real practice does. In true diabetics, 99% have an HbA1c and 99% have a creatinine every year. Each draw is kept with a per-lab probability, solved so that the share of true diabetics with at least one result per calendar year matches published Medicare benchmarks:

| Lab | Target annual testing in diabetics | Source |
|---|---|---|
| HbA1c | 83.3% | Yasaitis et al., PLOS ONE 2014 |
| eGFR (creatinine) | 83.6% | Alfego et al., Diabetes Care 2021 |
| uACR | 42.2% | USRDS 2019 ADR, as cited in Alfego et al. 2021 |

The solved keep probabilities were 0.70 for HbA1c, 0.61 for creatinine, and 0.16 for uACR (`output/tables/lab_missingness_calibration.csv`). The same keep probability applies to everyone, not just diabetics. So patients with fewer visits end up with fewer results. That is the point: the access gap comes out of the design rather than being added in by hand.

**Sensitivity runs.** Two extra lab-model runs change the eGFR spread for people without CKD: half-normal SD 10, which puts more of them just above 60, and SD 20.

## 8. Rules

Every rule only looks at the window, January 1, 2024 to December 31, 2025. eGFR is CKD-EPI 2021 (race-free), using age on the draw date.

| Tier | Diabetes (HCC 38) | CKD (HCC 329 / 328 / 327) |
|---|---|---|
| Single lab | Any HbA1c of 6.5% or higher | Any eGFR under 60. Staged by the worst value |
| Guideline | ADA: two HbA1c of 6.5% or higher on different days | KDIGO: eGFR under 60 on two draws at least 90 days apart. Staged by the median low value |
| Revalidation hybrid | Guideline, or one abnormal HbA1c plus an active glucose-lowering drug | Outpatient draws only. Chronicity as above, or one low eGFR plus uACR of 30 or more. In both cases, the most recent outpatient eGFR must still be under 60. Staged by the median low outpatient value |

Glucose is left out of the diabetes rules. Synthea caps glucose at 199.7 mg/dL and never records whether the patient was fasting, so neither ADA glucose criterion can be applied honestly.

Staging: eGFR 45 to 59.9 is HCC 329, 30 to 44.9 is HCC 328, and under 30 is HCC 327. A lab-stage-5 result without dialysis or ESRD documentation is credited as 327. That is conservative, because 326 pays more.

**Alerts and scoring**
- The rules flag every cohort patient. A flag becomes an alert only if that condition family is not documented after masking.
- Among undocumented patients, the masked ones are the true positives.
- PPV and sensitivity come with 95% Wilson intervals. Alert burden is alerts per 100 cohort patients.
- **Masked RAF** is the sum of the true HCC coefficients for every masked case.
- **Recovered RAF** is the sum over true-positive alerts of the smaller of the alerted and true HCC coefficients, so overstaging earns nothing extra.
- **False RAF** is the sum of coefficients on false-positive alerts. That is what would be submitted with no clinical support, the kind of thing a RADV audit claws back.

## 9. SQL and R reconciliation

The rules are written twice, once in SQL (`sql/30_rules.sql`) and once in R (`R/rules.R`), without one being translated from the other. Both read the same lab table. Step 60 compares every scenario at the pair level (patient by target HCC). A pair agrees only if all three tier flags match. Anything that disagrees is written out with the inputs needed to trace it, and each root cause gets a unit test. The details of what was found are in `docs/decision_log.md`.

## 10. MIMIC-IV check

`mimic/run_mimic_ckd.R` applies the same KDIGO logic to real hospital data:
- eGFR from blood creatinine (lab items picked by name and fluid).
- Age from `anchor_age`.
- Draws with a hospital admission ID count as acute; the rest count as outpatient.

It then asks how many patients who meet the lab criteria have no CKD-related code anywhere in their record. That means ICD-10 N18, I12, I13, E08 to E13 .22, Z99.2, or Z49, or ICD-9 585, 403, 404, V45.11, or V56.

The flagged patients without a code go into `nephrology_review_packet.csv`, which a nephrologist can fill out. `mimic/score_review.R` then turns their answers into PPV for each rule.

**Demo results** (all 100 patients have at least one creatinine):
- 20 meet the KDIGO lab definition, and 5 of them (25%, Wilson 95% CI 11.2% to 46.9%) have no CKD code. Among patients 65 or older at anchor, it's 4 of 12 (33%).
- All 5 uncoded patients carry an acute kidney injury code (ICD-10 N17 or ICD-9 584).
- 11 patients meet the outpatient-only hybrid, and 2 of them are uncoded (18%).

Item 52546 (a second blood creatinine item) has no rows in the demo. Five creatinine results were stored twice at the same chart time and are counted once.

## 11. Limitations worth saying out loud

- **The headline numbers come from a simulation.** PPV and sensitivity reflect the lab model and the masking rates as much as the rules. They show how the rules behave relative to each other under realistic noise and missingness. They are not an estimate of real-world performance.
- **Masking is random.** In real life, undocumented cases are probably milder and seen less often than documented ones, so real sensitivity is likely lower.
- **CKD is less common in Synthea than in real life.** 12.1% of the cohort has coded stage 3 or worse. CDC puts CKD of any stage at 34% of adults 65 and older (2021 to 2023 data). And once true stage 3 to 4 is tied to a true eGFR under 60, CKD sensitivity comes out near 1. That is a property of the model, not something to expect in practice.
- **The drug signal is only as good as the drug data.** The diabetes hybrid uses any glucose-lowering drug as support. With Synthea's insulin-for-prediabetes records included, that signal is noisy. In real practice, GLP-1 drugs used for weight loss would create a similar but smaller problem.
- **The MIMIC demo has 100 patients.** Its numbers are a working check of the code on real data structure, not a prevalence estimate.
- **Hand-mapped crosswalk.** It was built by one person, without a second coder or the licensed NLM map.
