# mask.R
# Hides documentation for a random share of patients who truly have a condition.
# Those hidden cases are the "undocumented" conditions the rules are supposed to find.
#
# Masking is done per condition family, not per code: if a diabetic patient is masked,
# every code that maps to HCC 36, 37 or 38 disappears together. Otherwise a leftover
# complication code would still give the diagnosis away.

make_masks <- function(truth, rate_dm, rate_ckd, seed) {
  truth <- as.data.table(truth)[order(patient_id)]
  set.seed(seed)

  dm <- truth[dm_true == TRUE, .(patient_id, family = "DM", true_hcc = dm_hcc)]
  dm[, masked := runif(.N) < rate_dm]

  # HCC 326 (stage 5 / ESRD) is out of scope, so those patients stay documented
  ckd <- truth[ckd_hcc %in% c(327L, 328L, 329L), .(patient_id, family = "CKD", true_hcc = ckd_hcc)]
  ckd[, masked := runif(.N) < rate_ckd]

  rbind(dm, ckd)
}

# One row per cohort patient: is each family still documented after masking?
documented_after_mask <- function(truth, masks) {
  truth <- as.data.table(truth)
  m <- dcast(masks, patient_id ~ family, value.var = "masked")
  out <- merge(truth[, .(patient_id, dm_true, ckd_hcc)], m, by = "patient_id", all.x = TRUE)
  if (!"DM" %in% names(out))  out[, DM := NA]
  if (!"CKD" %in% names(out)) out[, CKD := NA]
  out[, `:=`(
    dm_documented  = dm_true & !(DM %in% TRUE),
    ckd_documented = !is.na(ckd_hcc) & !(CKD %in% TRUE),
    dm_masked      = DM %in% TRUE,
    ckd_masked     = CKD %in% TRUE
  )]
  out[, .(patient_id, dm_documented, ckd_documented, dm_masked, ckd_masked)]
}
