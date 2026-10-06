# rules.R
# R version of the detection rules. sql/30_rules.sql is the SQL version.
# The two were written separately on purpose and are compared pair by pair in step 60.
#
# Rules run on every cohort patient. Whether a flag becomes an alert depends on whether the
# condition is already documented, and that filter is applied later in evaluation.
#
# Tiers, for both conditions:
#   t1  single lab       one abnormal result anywhere in the two-year window
#   t2  guideline        ADA: two abnormal HbA1c on different days
#                        KDIGO: eGFR under 60 on two draws at least 90 days apart
#   t3  revalidation     the flag has to be re-validated before it alerts
#       hybrid           DM: t2, or t1 plus a glucose-lowering drug
#                        CKD: outpatient draws only; KDIGO chronicity or one low eGFR plus
#                        albuminuria (uACR 30+); and the most recent outpatient eGFR is still under 60

TARGET_HCCS <- c(38L, 329L, 328L, 327L)

rules_dm <- function(labs, dm_med, sp) {
  a1c <- labs[lab == "a1c" & value >= sp$a1c_threshold]
  dm <- a1c[, .(n_abnormal = .N, n_abnormal_days = uniqueN(draw_date)), by = patient_id]
  dm[, t1 := n_abnormal >= 1]
  dm[, t2 := n_abnormal_days >= 2]
  dm[, on_dm_med := patient_id %in% dm_med$patient_id]
  dm[, t3 := t2 | (t1 & on_dm_med)]
  dm[, .(patient_id,
         hcc_t1 = fifelse(t1, 38L, NA_integer_),
         hcc_t2 = fifelse(t2, 38L, NA_integer_),
         hcc_t3 = fifelse(t3, 38L, NA_integer_))]
}

rules_ckd <- function(labs, cohort, sp) {
  cr <- merge(labs[lab == "creatinine"], cohort[, .(patient_id, birth_date, sex)], by = "patient_id")
  cr[, age := age_on(draw_date, birth_date)]
  cr[, egfr := egfr_ckd_epi_2021(value, age, sex)]
  low <- cr[egfr < sp$egfr_threshold]

  # Grouped summaries on a zero-row table still evaluate j once in data.table, and
  # max() of nothing is -Inf, which breaks date math. Return a typed empty table instead.
  # (Caught by the "low value in the hospital" unit test.)
  span_summary <- function(x) {
    if (nrow(x) == 0) {
      return(data.table(patient_id = integer(), n_low = integer(), span = integer(), egfr_med = numeric()))
    }
    x[, .(n_low = .N, span = as.integer(max(draw_date) - min(draw_date)), egfr_med = median(egfr)),
      by = patient_id]
  }

  # t1: any low value, staged by the worst one
  t1 <- low[, .(hcc_t1 = hcc_from_egfr(min(egfr))), by = patient_id]

  # t2: KDIGO chronicity using every draw, staged by the median low value
  t2 <- span_summary(low)[span >= sp$kdigo_min_days, .(patient_id, hcc_t2 = hcc_from_egfr(egfr_med))]

  # t3: outpatient draws only, must still be low at the latest outpatient draw
  op <- cr[setting == "outpatient"]
  setorder(op, patient_id, draw_ts, draw_id)
  last_op <- op[, .SD[.N], by = patient_id][, .(patient_id, last_egfr = egfr)]
  op_low <- span_summary(op[egfr < sp$egfr_threshold])
  alb <- unique(labs[lab == "uacr" & value >= sp$uacr_threshold, .(patient_id)])[, albuminuria := TRUE]
  t3 <- merge(op_low, last_op, by = "patient_id")
  t3 <- merge(t3, alb, by = "patient_id", all.x = TRUE)
  t3[is.na(albuminuria), albuminuria := FALSE]
  t3 <- t3[(span >= sp$kdigo_min_days | albuminuria) & last_egfr < sp$egfr_threshold,
           .(patient_id, hcc_t3 = hcc_from_egfr(egfr_med))]

  out <- merge(merge(t1, t2, by = "patient_id", all = TRUE), t3, by = "patient_id", all = TRUE)
  out[]
}

# Returns one row per cohort patient per target HCC with a TRUE/FALSE flag for each tier.
apply_rules <- function(labs, cohort, dm_med, sp) {
  labs <- as.data.table(labs)
  cohort <- as.data.table(cohort)
  dm  <- rules_dm(labs, as.data.table(dm_med), sp)
  ckd <- rules_ckd(labs, cohort, sp)

  grid <- CJ(patient_id = cohort$patient_id, hcc = TARGET_HCCS)
  long <- rbind(
    melt(dm,  id.vars = "patient_id", variable.name = "tier", value.name = "flag_hcc"),
    melt(ckd, id.vars = "patient_id", variable.name = "tier", value.name = "flag_hcc")
  )[!is.na(flag_hcc)]
  long[, tier := sub("hcc_", "", tier)]
  long[, hit := TRUE]
  wide <- dcast(long, patient_id + flag_hcc ~ tier, value.var = "hit", fill = FALSE)
  setnames(wide, "flag_hcc", "hcc")
  out <- merge(grid, wide, by = c("patient_id", "hcc"), all.x = TRUE)
  for (t in c("t1", "t2", "t3")) {
    if (!t %in% names(out)) out[, (t) := FALSE]
    set(out, which(is.na(out[[t]])), t, FALSE)
  }
  setorder(out, patient_id, hcc)
  out[, .(patient_id, hcc, t1, t2, t3)]
}
