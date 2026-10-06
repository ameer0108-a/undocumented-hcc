fake_truth <- function(n = 4000) {
  set.seed(1)
  data.table(patient_id = 1:n,
             dm_true = runif(n) < 0.35,
             dm_hcc = 38L,
             prediabetes = FALSE,
             ckd_stage_coded = sample(0:5, n, replace = TRUE, prob = c(.6, .1, .1, .1, .07, .03)),
             age = sample(65:95, n, replace = TRUE),
             sex = sample(c("F", "M"), n, replace = TRUE))[
    , ckd_hcc := fcase(ckd_stage_coded == 3, 329L, ckd_stage_coded == 4, 327L,
                       ckd_stage_coded == 5, 326L, default = NA_integer_)]
}

test_that("masking is reproducible and only touches eligible patients", {
  tr <- fake_truth()
  m1 <- make_masks(tr, 0.276, 0.51, 99)
  m2 <- make_masks(tr, 0.276, 0.51, 99)
  expect_identical(m1, m2)
  expect_true(all(m1[family == "DM", patient_id] %in% tr[dm_true == TRUE, patient_id]))
  expect_false(any(m1[family == "CKD", true_hcc] == 326L))
  expect_equal(mean(m1[family == "DM", masked]), 0.276, tolerance = 0.03)
})

test_that("a masked family is never counted as documented", {
  tr <- fake_truth()
  m <- make_masks(tr, 0.3, 0.5, 7)
  d <- documented_after_mask(tr, m)
  expect_false(any(d$dm_documented & d$dm_masked))
  expect_false(any(d$ckd_documented & d$ckd_masked))
  # stage 5 stays documented
  expect_true(all(d[patient_id %in% tr[ckd_hcc == 326L, patient_id], ckd_documented]))
})

test_that("latent eGFR stays inside the KDIGO range for each coded stage", {
  lp <- lab_params()
  lat <- draw_latent(fake_truth(), lp, 5)
  rng <- lat[, .(lo = min(egfr_true), hi = max(egfr_true)), by = ckd_stage_coded]
  expect_gte(rng[ckd_stage_coded == 0, lo], 60)
  expect_gte(rng[ckd_stage_coded == 3, lo], 30); expect_lt(rng[ckd_stage_coded == 3, hi], 60)
  expect_gte(rng[ckd_stage_coded == 4, lo], 15); expect_lt(rng[ckd_stage_coded == 4, hi], 30)
  expect_lt(rng[ckd_stage_coded == 5, hi], 15)
})

test_that("retention calibration lands on the testing-rate target", {
  set.seed(3)
  d <- data.table(patient_id = rep(1:500, each = 6), lab = "a1c", dm_true = TRUE,
                  draw_date = as.IDate(rep(c("2024-03-01", "2024-09-01", "2024-12-01",
                                             "2025-03-01", "2025-09-01", "2025-12-01"), 500)))
  d[, u_keep := runif(.N)]
  cal <- calibrate_retention(d, 1:500, list(a1c = 0.833), 2024:2025)
  expect_equal(cal$achieved_rate, 0.833, tolerance = 0.005)
  expect_lt(cal$retention_p, 1)
})
