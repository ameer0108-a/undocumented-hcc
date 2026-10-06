test_that("eGFR maps to the right V28 kidney HCC at every boundary", {
  expect_true(is.na(hcc_from_egfr(60)))
  expect_equal(hcc_from_egfr(59.999), 329L)
  expect_equal(hcc_from_egfr(45), 329L)
  expect_equal(hcc_from_egfr(44.999), 328L)
  expect_equal(hcc_from_egfr(30), 328L)
  expect_equal(hcc_from_egfr(29.999), 327L)
  expect_equal(hcc_from_egfr(8), 327L)   # stage 5 without dialysis is credited as 327
  expect_true(is.na(hcc_from_egfr(NA_real_)))
})

test_that("KDIGO categories use left-closed intervals", {
  expect_equal(as.character(egfr_category(c(90, 89.9, 60, 59.9, 45, 30, 15, 14.9))),
               c("G1", "G2", "G2", "G3a", "G3a", "G3b", "G4", "G5"))
})

test_that("age_on counts completed years, including leap-day birthdays", {
  expect_equal(age_on("2025-03-14", "1950-03-14"), 75L)
  expect_equal(age_on("2025-03-13", "1950-03-14"), 74L)
  expect_equal(age_on("2025-02-28", "1960-02-29"), 64L)
  expect_equal(age_on("2025-03-01", "1960-02-29"), 65L)
})

test_that("Wilson interval matches a textbook example", {
  ci <- wilson_ci(8, 10)
  expect_equal(round(ci$lo, 3), 0.490)
  expect_equal(round(ci$hi, 3), 0.943)
  zero <- wilson_ci(0, 25)
  expect_equal(zero$lo, 0)
  expect_gt(zero$hi, 0)
})
