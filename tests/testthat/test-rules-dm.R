sp <- test_params()
no_meds <- data.table(patient_id = integer())

dm_flags <- function(labs, meds = no_meds) {
  out <- rules_dm(labs, meds, sp)
  function(id, col) {
    v <- out[patient_id == id][[col]]
    length(v) == 1 && !is.na(v)
  }
}

test_that("one abnormal HbA1c is a single-lab flag only", {
  f <- dm_flags(lab_rows(1L, "a1c", "2025-05-01", 6.6))
  expect_true(f(1, "hcc_t1")); expect_false(f(1, "hcc_t2")); expect_false(f(1, "hcc_t3"))
})

test_that("two abnormal results on the same day do not meet ADA confirmation", {
  f <- dm_flags(lab_rows(2L, "a1c", c("2025-05-01", "2025-05-01"), c(6.8, 7.0)))
  expect_true(f(2, "hcc_t1")); expect_false(f(2, "hcc_t2"))
})

test_that("two abnormal results on different days meet ADA and the hybrid", {
  f <- dm_flags(lab_rows(3L, "a1c", c("2024-11-01", "2025-05-01"), c(6.8, 7.0)))
  expect_true(f(3, "hcc_t2")); expect_true(f(3, "hcc_t3"))
})

test_that("6.5 exactly counts as abnormal, and a drug re-validates a single result", {
  meds <- data.table(patient_id = 4L)
  f <- dm_flags(lab_rows(4L, "a1c", "2025-05-01", 6.5), meds)
  expect_true(f(4, "hcc_t1")); expect_false(f(4, "hcc_t2")); expect_true(f(4, "hcc_t3"))
})

test_that("6.4 never flags, even with a drug", {
  meds <- data.table(patient_id = 5L)
  out <- rules_dm(lab_rows(5L, "a1c", c("2024-02-01", "2025-02-01"), c(6.4, 6.4)), meds, sp)
  expect_equal(nrow(out), 0)
})
