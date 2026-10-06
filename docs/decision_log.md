# Decision log

Running notes on what was decided, what broke, and why things are the way they are. Newest at the bottom.

---

**Scope.** Four V28 HCCs with a clean lab signal: 38 (diabetes), 329, 328, and 327 (CKD 3a, 3b, 4). Stage 5 and ESRD (326) are out. Those patients are in the ESRD model and nearly always documented through dialysis anyway.

**Index date.** December 31, 2025. Measurement year 2025 feeds payment year 2026, which is the first year at 100% V28. Labs look back two years, so a 90-day KDIGO chronicity check has room to work.

**Synthetic population.** Synthea, North Carolina, ages 65 to 100 requested, 20 batches of 1,000, seeds 20250001 to 20250020, only living patients exported. Generating a full all-ages population and filtering to 65+ would have taken about 7 times the compute and disk for the same cohort, so the generation is age-targeted.

**Loader.** Raw Synthea CSVs repeat UUIDs and long descriptions on every row. A test batch was 411 MB as CSV and 187 MB after normalizing (integer keys, one concept table). Each batch is deleted after loading, so peak disk stays around 1 GB.

**Crosswalk.** Hand-mapped every SNOMED disorder Synthea produced to ICD-10-CM, because the NLM map needs a UMLS license. First pass had 5 codes that don't exist as billable codes in ICD-10-CM: T30.1, T30.2, T30.3 (degree-specific burns need a body region), T09.3, and T08.XXXA (spine injuries need a level). Swapped to T30.0 and T14.8XXA, with a note on each row.

**Raw labs don't hold up.** First look at batch 1 before writing any rules:
- HbA1c in true diabetics: about 7.1% in the year after diagnosis, then roughly half of later values under 4.0%. Synthea's drug effect overshoots.
- Creatinine of 2.5 to 3.5 mg/dL in people with no kidney disease. Traced to `veteran_hyperlipidemia.json` and `colorectal_cancer.json`, which hard-code that range on every CMP.
- Patients coded CKD stage 1 or 2 almost all have creatinine that implies stage 3 or worse. `kidney_conditions.json` assigns fixed ranges per stage that aren't tied to any eGFR equation.
- Glucose never reaches 200 (capped at 199.7), and fasting status isn't recorded.
- Insulin prescribed with prediabetes as the reason code.

**Lab model instead of raw values.** Kept Synthea's patients, true conditions, visits, and the timing of every lab draw. Replaced the value on each result with one drawn from a documented model: each patient's stable true level comes from their true condition, then biological noise is added per draw, plus AKI spikes in acute settings. Missing tests are calibrated to Medicare testing rates. Raw results are still reported as their own scenario, so the before and after are both visible.

**Glucose dropped from the diabetes rule.** With a 199.7 cap and no fasting flag, neither ADA glucose criterion can be applied. The ADA rule is two HbA1c of 6.5% or higher on separate days.

**Insulin-for-prediabetes left in.** Real EHRs have plenty of non-specific prescriptions too. If the hybrid rule's drug path still holds up with this noise, that says something.

**Masking rates tied to published numbers.** Diabetes 27.6% (CDC). CKD 51% (CMS OMH, stage 3 coding rate in Medicare Advantage). PPV moves a lot with these rates, so a sweep from 10% to 60% is reported rather than hiding the dependence.

**Rules written twice.** SQL first, then R, separately, not translated line by line. Both read the same lab table, and the comparison is at the patient by HCC level with all three tiers.

**Bug 1, caught by a unit test: numeric literals in PostgreSQL.** The SQL eGFR function used bare constants like `0.9938` and `1.012`. PostgreSQL types those as `numeric`, not `double precision`, so `power(0.9938, age)` runs in exact decimal math and the result differs from R in the last few bits. `test-sql-parity.R` compares the two functions bit for bit and failed. Fixed by casting every constant to `float8`. The old function is kept as `ref.egfr_ckd_epi_2021_numeric_literals` so step 60 can check whether it would ever have flipped a result on the real data.

**Bug 2, caught by a unit test: empty groups in data.table.** If no patient has a low outpatient eGFR, a grouped summary on a zero-row table still evaluates once, `max()` of nothing returns `-Inf`, and the date subtraction errors out. The "low value in the hospital is ignored" test hit this. Fixed with a typed empty return.

**MIMIC.** No credentialed access, so the real-data check runs on the open MIMIC-IV demo (100 patients). The script picks lab items by name and fluid instead of hard-coded item IDs, so the same file runs on the full dataset. It was checked first against a six-patient made-up file set in MIMIC format (`tests/fixtures/mimic_mini`), where each patient exercises one path: coded with ICD-10, coded with ICD-9, AKI-only, albuminuria path, normal.

**Build hiccup.** Batch 16 got OOM-killed. Java had `-Xmx5g` on a 7 GB machine that was also running PostgreSQL. Dropped the heap to 3.5 GB, and the build script picked up where it stopped (it skips batches already in `ehr.load_log`). Final count: 20 batches, 20,000 patients, 55,844,767 records.

**Crosswalk, second pass.** The full cohort turned up 19 disorder concepts that weren't in the first three batches, 11 of them chronic. Coverage of chronic disorder records was 99.98% before mapping them and 100% after. All 19 new codes validated against the April 2026 code set on the first try.

**Diabetes truth was wrong on the first full run.** Truth was originally "any active code in HCC 36 to 38". On the full data, that called 7,945 patients diabetic, but only 3,947 of them ever had a type 2 diabetes diagnosis. The other 3,998 had only kidney codes that Synthea labels "due to diabetes" (nephropathy, microalbuminuria, proteinuria). Tracing it back: `chronic_kidney_disease.json` runs for hypertension or diabetes, but `kidney_conditions.json` always names the result as diabetic. Changed diabetes truth to the diagnosis itself and flagged the others as `dm_code_artifact`. This moved the results a lot. Diabetes PPV for the hybrid went from 0.96 to 0.65, because the drug path now meets real non-diabetics on insulin (next entry). The earlier numbers were wrong, not better.

**Insulin-for-prediabetes is bigger than it looked.** 2,539 of 9,480 prediabetic patients (26.8%) are on insulin during the window. Since the plan was to leave it in, the main analysis keeps it, and the hybrid's diabetes PPV (0.65) comes in under the ADA rule (0.74). A sensitivity analysis drops prescriptions that have prediabetes as the reason. There, the hybrid reaches 0.78 PPV at 0.70 sensitivity, compared with the ADA rule's 0.74 at 0.57. Both versions are reported. The lesson is that a drug signal is only as specific as the prescribing behind it.

**Full-data reconciliation.** SQL and R agreed on all 78,084 patient by HCC pairs (19,521 patients by 4 HCCs) in every scenario on the first full run. The numeric-literal bug had already been fixed by then, so step 60 measures what it would have done: it changed every one of 161,277 creatinine-based eGFR values by up to 2.1e-13, and flipped no threshold or stage. It would only matter for a value within about 1e-13 of a cutoff. With creatinine reported to two decimals, that never happens here, but nothing in the code guaranteed it.

**HbA1c testing target not reachable by thinning alone, at first.** With the original (wrong) diabetes truth, Synthea's annual HbA1c rate was already below the 83.3% target, so nothing was thinned. With the corrected truth, real diabetics are tested 99% of the time, and the solved keep probability is 0.70. Mentioning it because the calibration table looked different between runs.

**MIMIC-IV demo run.** Ran the KDIGO script on the open demo (100 patients, checksums verified against the release's SHA256SUMS). 20 patients meet the lab criteria, and 5 of them (25%) have no CKD code. Every one of the 5 has an acute kidney injury code, so the most likely story is AKI rather than missed CKD. The outpatient-only hybrid keeps 2 of the 5. Two small fixes came out of looking at the real files. Five creatinine results were stored twice at the same chart time, so they're now counted once. And the packet now lists each patient's AKI codes, because that's the first thing a reviewer would ask for. A second blood creatinine item (52546) matched by name but has no rows in the demo.
