# CKD-EPI 2021 checks. Expected values are worked by hand from the published equation
# (Inker et al., NEJM 2021) and match the NKF online calculator to the nearest whole number.

test_that("CKD-EPI 2021 matches hand-worked reference values", {
  expect_equal(round(egfr_ckd_epi_2021(1.0, 60, "M")), 86)
  expect_equal(round(egfr_ckd_epi_2021(1.0, 60, "F")), 64)
  expect_equal(round(egfr_ckd_epi_2021(0.6, 50, "F")), 109)
  expect_equal(round(egfr_ckd_epi_2021(2.0, 80, "M")), 33)
})

test_that("eGFR falls as creatinine rises, for both sexes", {
  scr <- seq(0.4, 6, by = 0.05)
  for (s in c("F", "M")) {
    e <- egfr_ckd_epi_2021(scr, 72, s)
    expect_true(all(diff(e) < 0))
  }
})

test_that("inverse equation gives back the creatinine it started from", {
  grid <- CJ(scr = c(0.5, 0.7, 0.9, 1.2, 2, 3.5), age = c(65, 80, 95), sex = c("F", "M"))
  grid[, egfr := egfr_ckd_epi_2021(scr, age, sex)]
  grid[, back := scr_from_egfr(egfr, age, sex)]
  expect_equal(grid$back, grid$scr, tolerance = 1e-10)
})

test_that("the equation is continuous at the kappa knot", {
  # just under and just over kappa should give nearly the same eGFR
  for (s in c("F", "M")) {
    k <- if (s == "F") 0.7 else 0.9
    expect_lt(abs(egfr_ckd_epi_2021(k - 1e-9, 70, s) - egfr_ckd_epi_2021(k + 1e-9, 70, s)), 1e-6)
  }
})
