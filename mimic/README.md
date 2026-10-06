# MIMIC-IV check

The Synthea results say how the rules behave on data where the answer is known. This folder asks a different question on real hospital data: of the patients whose labs meet KDIGO criteria for CKD, how many have no CKD code anywhere in their record?

## Result on the demo

- 20 of 100 patients meet the KDIGO lab criteria.
- 5 of those 20 (25%, 95% CI 11% to 47%) have no CKD code. All 5 have an acute kidney injury code.
- The outpatient-only hybrid flags 11 patients, 2 of them uncoded.
- The review packet in `mimic/output/` holds the 5 uncoded patients.

## Getting the data

The MIMIC-IV Clinical Database Demo is open access. No account and no training are needed.

1. Go to https://physionet.org/content/mimic-iv-demo/2.2/
2. Scroll to "Files" and click "Download the ZIP file" (about 15 MB).
3. Unzip it into `mimic/data/`, so you end up with `mimic/data/mimic-iv-clinical-database-demo-2.2/hosp/labevents.csv.gz` and so on.

`mimic/data/` is in `.gitignore`. The demo is licensed under the Open Data Commons Open Database License, which allows redistribution with attribution, but there's no reason to commit it.

## Running it

From the repo root:

```
Rscript mimic/run_mimic_ckd.R mimic/data/mimic-iv-clinical-database-demo-2.2
```

Outputs go to `mimic/output/`:

- `mimic_ckd_summary.csv`: counts and the percent without a CKD code, with a Wilson 95% CI
- `mimic_ckd_patients.csv`: every patient who met either rule
- `nephrology_review_packet.csv`: flagged patients with no CKD code, ready for a reviewer

## The review packet

Each row is one patient with:
- the lab facts a reviewer needs: number of low eGFR values, the days between the first and last, the lowest, median, and most recent outpatient eGFR, and whether there was albuminuria
- the stage the rule suggests
- four blank columns: `reviewer_ckd_present` (Y or N), `reviewer_stage`, `reviewer_reason_if_no` (for example "AKI only", "single admission", "muscle wasting"), and `reviewer_initials`

Once it's filled in:

```
Rscript mimic/score_review.R mimic/output/nephrology_review_packet_completed.csv mimic/output/mimic_ckd_patients.csv
```

That reports how often the reviewer agreed with each rule, and lists the most common reasons for "no". Those reasons are the best guide to the next version of the rule.

## Full MIMIC-IV

The same script runs unchanged on the credentialed hosp module. If you ever get access, keep two things in mind: the data use agreement doesn't allow sharing the data, and that includes pasting rows into an AI tool. Run it locally and only share aggregate counts.
