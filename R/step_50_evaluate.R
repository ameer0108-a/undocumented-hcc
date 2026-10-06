# step_50_evaluate.R
# Scores every scenario and tier, then writes the tables used in the write-up and slides.

Sys.setenv(TZ = "UTC")
source("R/utils.R"); source("R/mask.R"); source("R/evaluate.R"); source("R/rules.R")

sp <- study_params()
coef <- v28_coef()
con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)
q <- function(sql) as.data.table(DBI::dbGetQuery(con, sql))
out <- function(x, name) fwrite(x, file.path("output/tables", paste0(name, ".csv")))
dir.create("output/tables", showWarnings = FALSE, recursive = TRUE)

cohort     <- q("select * from study.cohort")
truth      <- q("select * from study.truth")
documented <- q("select * from study.documented")
latent     <- q("select * from study.lab_latent")
flags      <- q("select * from study.rule_flag_sql")
n_cohort   <- nrow(cohort)

# ---------------------------------------------------------------- data size and cohort
records <- q("
  select 'patient' as tbl, count(*) as n from ehr.patient
  union all select 'encounter', count(*) from ehr.encounter
  union all select 'condition', count(*) from ehr.condition
  union all select 'observation', count(*) from ehr.observation
  union all select 'medication', count(*) from ehr.medication
  union all select 'procedure', count(*) from ehr.procedure
  union all select 'immunization', count(*) from ehr.immunization
  union all select 'careplan', count(*) from ehr.careplan
  union all select 'allergy', count(*) from ehr.allergy
  union all select 'device', count(*) from ehr.device
  union all select 'supply', count(*) from ehr.supply
  union all select 'imaging_study', count(*) from ehr.imaging_study")
records <- rbind(records, data.table(tbl = "TOTAL", n = sum(records$n)))
out(records, "ehr_record_counts")
out(q("select * from study.attrition order by step"), "cohort_attrition")
out(q("select * from study.crosswalk_coverage"), "crosswalk_coverage")
out(q("select snomed_code, description, n_records, share_open from study.chronic_concept order by n_records desc"),
    "chronic_concepts")

ct <- merge(cohort, truth, by = "patient_id")
table1 <- data.table(
  measure = c("Patients", "Age, mean (SD)", "Age 75 or older, %", "Female, %",
              "Office visit days per year, median (IQR)",
              "Visit band: 2 or fewer per year, %", "Visit band: 3 to 5, %", "Visit band: 6 or more, %",
              "True diabetes (HCC 36-38), %", "Prediabetes without diabetes, %",
              "True CKD stage 3 (HCC 329), %", "True CKD stage 4 (HCC 327), %", "ESRD / stage 5 (HCC 326), %",
              "CKD stage 3-4 patients without diabetes, %",
              "Kidney codes labeled 'due to diabetes' but no diabetes diagnosis, %"),
  value = c(
    format(n_cohort, big.mark = ","),
    sprintf("%.1f (%.1f)", mean(ct$age), sd(ct$age)),
    sprintf("%.1f", 100 * mean(ct$age >= 75)),
    sprintf("%.1f", 100 * mean(ct$sex == "F")),
    sprintf("%.1f (%.1f to %.1f)", median(ct$visits_per_year), quantile(ct$visits_per_year, .25), quantile(ct$visits_per_year, .75)),
    sprintf("%.1f", 100 * mean(ct$visit_band == "2 or fewer")),
    sprintf("%.1f", 100 * mean(ct$visit_band == "3 to 5")),
    sprintf("%.1f", 100 * mean(ct$visit_band == "6 or more")),
    sprintf("%.1f", 100 * mean(ct$dm_true)),
    sprintf("%.1f", 100 * mean(ct$prediabetes)),
    sprintf("%.1f", 100 * mean(ct$ckd_hcc %in% 329L)),
    sprintf("%.1f", 100 * mean(ct$ckd_hcc %in% 327L)),
    sprintf("%.1f", 100 * mean(ct$ckd_hcc %in% 326L)),
    sprintf("%.1f", 100 * ct[ckd_hcc %in% c(327L, 328L, 329L), mean(!dm_true)]),
    sprintf("%.1f", 100 * mean(ct$dm_code_artifact))
  ))
out(table1, "table1_cohort")

# ---------------------------------------------------------------- raw Synthea lab artifacts
artifacts <- q("
  with t as (select * from study.truth),
  a1c as (
    select d.patient_id, d.synthea_value v from study.lab_draw d join t using (patient_id)
    where d.lab = 'a1c' and t.dm_true),
  cr as (
    select d.*, rk.description as reason, t.ckd_stage_coded
    from study.lab_draw d join t using (patient_id)
    left join ehr.encounter e on e.encounter_id = d.encounter_id
    left join ehr.concept rk on rk.concept_id = e.reason_concept_id
    where d.lab = 'creatinine')
  select 'HbA1c draws in true diabetics' as check_name, count(*) as n,
         round(100.0 * avg((v < 4)::int), 1) as pct_flagged, 'below 4.0 percent (not physiologically plausible)' as flag
  from a1c
  union all
  select 'HbA1c draws in true diabetics', count(*), round(100.0 * avg((v >= 6.5)::int), 1), 'at or above 6.5 percent'
  from a1c
  union all
  select 'Creatinine draws at hyperlipidemia or colon cancer follow-ups', count(*),
         round(100.0 * avg((synthea_value between 2.5 and 3.5)::int), 1), 'hard-coded 2.5 to 3.5 mg/dL'
  from cr where reason in ('Hyperlipidemia (disorder)', 'Overlapping malignant neoplasm of colon (disorder)',
                           'Malignant neoplasm of colon (disorder)', 'Primary malignant neoplasm of colon (disorder)')
  union all
  select 'Creatinine draws in patients with no CKD code', count(*),
         round(100.0 * avg((synthea_value >= 2.5)::int), 1), 'at or above 2.5 mg/dL'
  from cr where ckd_stage_coded = 0
  union all
  select 'Creatinine draws in patients coded CKD stage 1 or 2', count(*),
         round(100.0 * avg((ref.egfr_ckd_epi_2021(synthea_value, 75, 'M') < 60)::int), 1),
         'imply eGFR under 60 even for a 75 year old man'
  from cr where ckd_stage_coded in (1, 2)")
artifacts <- rbind(artifacts, q("
  select 'Patients with a kidney code labeled due to diabetes' as check_name, count(*) as n,
         round(100.0 * avg((dm_code_artifact)::int) / nullif(avg((dm_code_artifact or dm_true)::int), 0), 1),
         'have no diabetes diagnosis (n counts patients, not draws)'
  from study.truth where dm_code_artifact or dm_true"), use.names = FALSE)
out(artifacts, "raw_lab_artifacts")

meds_artifact <- q("
  select (select count(*) from study.truth where prediabetes) as prediabetic_patients,
         count(distinct d.patient_id) as prediabetic_on_glucose_lowering_drug_in_window,
         round(100.0 * count(distinct d.patient_id) / (select count(*) from study.truth where prediabetes), 1) as pct
  from study.dm_med d join study.truth t using (patient_id)
  where t.prediabetes")
out(meds_artifact, "raw_medication_artifact")

# ---------------------------------------------------------------- main scoring
at <- alert_table(flags, documented, truth, latent)
perf <- score_all(at, n_cohort, coef)
perf[, tier_label := TIER_LABELS[tier]]
perf[, scenario_label := SCENARIO_LABELS[scenario]]
setorder(perf, scenario, family, tier)
out(perf, "performance_by_scenario_tier")

# Sensitivity analysis: diabetes hybrid with Synthea's insulin-for-prediabetes prescriptions removed.
# Uses the R rules on the main scenario's labs. Only the drug list changes.
labs_cal <- q("select draw_id, patient_id, lab, draw_ts, draw_date, setting, value
               from study.lab_value where scenario = 'calibrated' and lab = 'a1c'")
labs_cal[, draw_date := as.IDate(draw_date)]
dm_clean <- rules_dm(labs_cal, q("select patient_id from study.dm_med_clean"), sp)
flags_clean <- merge(CJ(patient_id = cohort$patient_id, hcc = 38L),
                     dm_clean[, .(patient_id, t1 = !is.na(hcc_t1), t2 = !is.na(hcc_t2), t3 = !is.na(hcc_t3))],
                     by = "patient_id", all.x = TRUE)
for (t in c("t1", "t2", "t3")) set(flags_clean, which(is.na(flags_clean[[t]])), t, FALSE)
flags_clean[, scenario := "calibrated_drug_artifact_removed"]
at_clean <- alert_table(flags_clean, documented, truth)
at_clean_all <- rbind(at_clean[family == "DM"],
                      at[scenario == "calibrated" & family == "CKD"][, scenario := "calibrated_drug_artifact_removed"],
                      fill = TRUE)
perf_clean <- score_all(at_clean_all, n_cohort, coef)
perf_clean[, tier_label := TIER_LABELS[tier]]
out(perf_clean, "sensitivity_dm_drug_artifact_removed")
print(perf_clean[, .(family, tier_label, alerts, ppv = fmt_ci(ppv, ppv_lo, ppv_hi), sensitivity = fmt_ci(sensitivity, sens_lo, sens_hi))])

# CKD stage agreement among true positives (lab model scenarios only)
stage <- at[family == "CKD" & alert & positive & scenario != "raw",
            .(n = .N), by = .(scenario, tier, alert_hcc, latent_hcc)]
out(stage, "ckd_stage_agreement")
stage_summary <- at[family == "CKD" & alert & positive & scenario != "raw",
                    .(tp = .N, exact_stage = sum(alert_hcc == latent_hcc),
                      pct_exact = 100 * mean(alert_hcc == latent_hcc),
                      pct_overstaged = 100 * mean(alert_hcc < latent_hcc)),
                    by = .(scenario, tier)]
out(stage_summary, "ckd_stage_agreement_summary")

# ---------------------------------------------------------------- access gap
at_v <- merge(at, cohort[, .(patient_id, visit_band, visits_per_year)], by = "patient_id")
gap <- rbind(
  score(at_v, n_cohort, coef, by = c("scenario", "tier", "family", "visit_band")),
  score(copy(at_v)[, family := "All 4 HCCs"], n_cohort, coef, by = c("scenario", "tier", "family", "visit_band"))
)
gap[, alerts_per_100 := NULL]
setorder(gap, scenario, family, tier, visit_band)
out(gap, "access_gap_by_visit_band")

# ---------------------------------------------------------------- PPV vs masking rate
rates <- seq(0.10, 0.60, by = 0.05)
sweep <- rbindlist(lapply(rates, function(r) {
  m <- make_masks(truth, r, r, sp$seed)
  d <- documented_after_mask(truth, m)
  a <- alert_table(flags[scenario == "calibrated"], d, truth)
  s <- score_all(a, n_cohort, coef)
  s[, mask_rate := r]
}))
out(sweep[, .(mask_rate, tier, family, alerts, tp, ppv, ppv_lo, ppv_hi, sensitivity, alerts_per_100)],
    "ppv_by_mask_rate")

# ---------------------------------------------------------------- headline numbers
main <- perf[scenario == "calibrated"]
head_tbl <- main[, .(family, tier = tier_label, alerts, alerts_per_100 = round(alerts_per_100, 1),
                     ppv = fmt_ci(ppv, ppv_lo, ppv_hi), sensitivity = fmt_ci(sensitivity, sens_lo, sens_hi),
                     pct_raf_recovered = round(pct_raf_recovered, 1),
                     false_raf = round(false_raf, 1))]
out(head_tbl, "headline_calibrated")
print(head_tbl)
cat("step 50 done\n")
