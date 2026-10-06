# lab_model.R
# Replaces Synthea's lab values with values from a documented measurement model.
#
# Why: Synthea's raw values can't test lab rules fairly (see docs/methods.md, "Raw lab artifacts").
# What stays from Synthea: who the patients are, what they truly have, and when and where
# each lab was drawn. What changes: the number on each result.
#
# Three layers:
#   1. a stable "true" level per patient (HbA1c mean, eGFR) set by their true condition
#   2. per-draw noise from published biological variation, plus AKI spikes in acute care
#   3. missing tests, thinned so annual testing in diabetics matches Medicare benchmarks
#
# Every random draw is made for every patient or draw, whether or not it is used,
# so changing one parameter does not reshuffle everything else.

draw_latent <- function(pts, lp, seed) {
  # pts needs: patient_id, age, sex, dm_true, prediabetes, ckd_stage_coded
  x <- as.data.table(pts)[order(patient_id)]
  n <- nrow(x)
  set.seed(seed + 1)

  a1c_dm   <- exp(rnorm(n, log(lp$a1c_dm_median), lp$a1c_dm_logsd))
  a1c_pre  <- runif(n, lp$a1c_pre_low, lp$a1c_pre_high)
  a1c_norm <- runif(n, lp$a1c_norm_low, lp$a1c_norm_high)

  g_nockd <- pmin(lp$egfr_nockd_floor + abs(rnorm(n, 0, lp$egfr_nockd_halfnormal_sd)), lp$egfr_cap)
  g1  <- runif(n, lp$egfr_g1_low,  lp$egfr_g1_high)
  g2  <- runif(n, lp$egfr_g2_low,  lp$egfr_g2_high)
  is3a <- runif(n) < lp$ckd3a_share
  g3a <- runif(n, lp$egfr_g3a_low, lp$egfr_g3a_high)
  g3b <- runif(n, lp$egfr_g3b_low, lp$egfr_g3b_high)
  g4  <- runif(n, lp$egfr_g4_low,  lp$egfr_g4_high)
  g5  <- runif(n, lp$egfr_g5_low,  lp$egfr_g5_high)

  x[, a1c_mu := fifelse(dm_true, a1c_dm, fifelse(prediabetes, a1c_pre, a1c_norm))]
  x[, egfr_true := fcase(
    ckd_stage_coded == 0, g_nockd,
    ckd_stage_coded == 1, g1,
    ckd_stage_coded == 2, g2,
    ckd_stage_coded == 3, fifelse(is3a, g3a, g3b),
    ckd_stage_coded == 4, g4,
    ckd_stage_coded == 5, g5
  )]
  x[, scr_true := scr_from_egfr(egfr_true, age, sex)]
  x[, latent_hcc := hcc_from_egfr(egfr_true)]
  x[]
}

simulate_values <- function(draws, latent, sp, lp, seed) {
  d <- merge(as.data.table(draws), latent[, .(patient_id, a1c_mu, scr_true, dm_true)],
             by = "patient_id")
  setorder(d, draw_id)
  n <- nrow(d)
  set.seed(seed + 2)
  z      <- rnorm(n)
  u_aki  <- runif(n)
  m_aki  <- runif(n, lp$aki_mult_low, lp$aki_mult_high)
  u_keep <- runif(n)

  a1c_cv <- fifelse(d$dm_true, sp$a1c_cv_dm, sp$a1c_cv_nodm)
  aki    <- d$setting == "acute" & u_aki < sp$aki_prob

  d[, model_value := fcase(
    lab == "a1c",        round(a1c_mu * exp(z * a1c_cv), 1),
    lab == "creatinine", round(scr_true * exp(z * sp$cr_cv) * fifelse(aki, m_aki, 1), 2),
    lab == "uacr",       synthea_value   # uACR kept as generated; see methods
  )]
  d[, aki_spike := aki & lab == "creatinine"]
  d[, u_keep := u_keep]
  d[]
}

# Share of true diabetics with at least one kept test of this lab in a calendar year,
# averaged over the two window years. Denominator is every true diabetic in the cohort,
# including people with no draws at all.
annual_testing_rate <- function(d, lab_name, p, dm_ids, years) {
  kept <- d[lab == lab_name & dm_true & u_keep < p, .(patient_id, yr = year(draw_date))]
  tested <- unique(kept)[yr %in% years, .N, by = yr]
  rates <- sapply(years, function(y) {
    k <- tested[yr == y, N]
    if (length(k) == 0) 0 else k / length(dm_ids)
  })
  mean(rates)
}

calibrate_retention <- function(d, dm_ids, targets, years) {
  rbindlist(lapply(names(targets), function(lab_name) {
    target <- targets[[lab_name]]
    f <- function(p) annual_testing_rate(d, lab_name, p, dm_ids, years) - target
    full <- f(1) + target
    p <- if (full <= target) 1 else uniroot(f, c(0, 1), tol = 1e-6)$root
    data.table(lab = lab_name, target_rate = target, synthea_rate = full,
               retention_p = p, achieved_rate = f(p) + target)
  }))
}

build_lab_values <- function(draws, pts, sp, lp, seed = sp$seed) {
  latent <- draw_latent(pts, lp, seed)
  d <- simulate_values(draws, latent, sp, lp, seed)
  dm_ids <- latent[dm_true == TRUE, patient_id]
  years <- year(as.IDate(sp$window_start)):year(as.IDate(sp$index_date))
  targets <- list(a1c = sp$target_a1c_testing_dm,
                  creatinine = sp$target_egfr_testing_dm,
                  uacr = sp$target_uacr_testing_dm)
  cal <- calibrate_retention(d, dm_ids, targets, years)
  d <- merge(d, cal[, .(lab, retention_p)], by = "lab")
  d[, kept := u_keep < retention_p]
  list(latent = latent, draws = d, calibration = cal)
}
