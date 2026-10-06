# evaluate.R
# Turns rule flags into alerts and scores them against the masked ground truth.
#
# An alert only exists for a patient whose condition family is NOT documented after masking.
# Among those patients, the true positives are exactly the masked cases.

FAMILY_HCCS <- list(DM = 38L, CKD = c(329L, 328L, 327L))

# One row per scenario x tier x family x undocumented patient, with alert status and HCCs.
alert_table <- function(flags, documented, truth, latent = NULL) {
  flags <- as.data.table(flags)
  long <- melt(flags, id.vars = c("scenario", "patient_id", "hcc"),
               measure.vars = c("t1", "t2", "t3"), variable.name = "tier", value.name = "flag")
  long[, tier := as.character(tier)]
  long[, family := fifelse(hcc == 38L, "DM", "CKD")]
  hits <- long[flag == TRUE, .(alert_hcc = min(hcc)), by = .(scenario, tier, family, patient_id)]

  doc <- as.data.table(documented)
  tr  <- as.data.table(truth)
  base <- rbind(
    doc[dm_documented == FALSE, .(patient_id, family = "DM", positive = dm_masked)],
    doc[ckd_documented == FALSE, .(patient_id, family = "CKD", positive = ckd_masked)]
  )
  base <- merge(base, tr[, .(patient_id, dm_hcc, ckd_hcc)], by = "patient_id")
  base[, true_hcc := fifelse(family == "DM", dm_hcc, ckd_hcc)]
  base[positive == FALSE, true_hcc := NA_integer_]
  base[, c("dm_hcc", "ckd_hcc") := NULL]
  if (!is.null(latent)) {
    base <- merge(base, as.data.table(latent)[, .(patient_id, latent_hcc)], by = "patient_id", all.x = TRUE)
    base[family == "DM", latent_hcc := NA_integer_]
  }

  grid <- CJ(scenario = unique(flags$scenario), tier = c("t1", "t2", "t3"))
  grid[, k := 1L]
  base[, k := 1L]
  out <- merge(grid, base, by = "k", allow.cartesian = TRUE)[, k := NULL]
  out <- merge(out, hits, by = c("scenario", "tier", "family", "patient_id"), all.x = TRUE)
  out[, alert := !is.na(alert_hcc)]
  out[]
}

score <- function(at, n_cohort, coef, by = c("scenario", "tier", "family")) {
  cf <- function(h) unname(coef[as.character(h)])
  at <- copy(at)
  at[, coef_true := fifelse(positive, cf(true_hcc), 0)]
  at[, coef_alert := fifelse(alert, cf(alert_hcc), 0)]
  at[, raf_recovered := fifelse(alert & positive, pmin(coef_true, coef_alert), 0)]
  at[, raf_false := fifelse(alert & !positive, coef_alert, 0)]

  res <- at[, .(
    n_undocumented = .N,
    n_masked       = sum(positive),
    alerts         = sum(alert),
    tp             = sum(alert & positive),
    fp             = sum(alert & !positive),
    fn             = sum(!alert & positive),
    masked_raf     = sum(coef_true),
    recovered_raf  = sum(raf_recovered),
    false_raf      = sum(raf_false)
  ), by = by]
  ppv  <- wilson_ci(res$tp, res$alerts)
  sens <- wilson_ci(res$tp, res$n_masked)
  res[, `:=`(ppv = ppv$est, ppv_lo = ppv$lo, ppv_hi = ppv$hi,
             sensitivity = sens$est, sens_lo = sens$lo, sens_hi = sens$hi,
             alerts_per_100 = 100 * alerts / n_cohort,
             pct_raf_recovered = 100 * recovered_raf / masked_raf)]
  res[]
}

score_all <- function(at, n_cohort, coef) {
  by_family <- score(at, n_cohort, coef)
  overall <- score(copy(at)[, family := "All 4 HCCs"], n_cohort, coef)
  rbind(by_family, overall)
}

TIER_LABELS <- c(t1 = "Single lab", t2 = "Guideline (ADA/KDIGO)", t3 = "Revalidation hybrid")
SCENARIO_LABELS <- c(raw = "Raw Synthea labs",
                     model_complete = "Lab model, no missing tests",
                     calibrated = "Lab model with missing tests (main)",
                     sens_egfr_sd10 = "Sensitivity: non-CKD eGFR closer to 60",
                     sens_egfr_sd20 = "Sensitivity: non-CKD eGFR spread wider")
