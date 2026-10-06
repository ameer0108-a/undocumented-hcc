# Runs mimic/run_mimic_ckd.R on a six-patient, made-up file set in MIMIC-IV format
# (tests/fixtures/mimic_mini). None of it is real MIMIC data. Each patient tests one path.

test_that("MIMIC script handles coding, AKI-only patterns, and the albuminuria path", {
  root <- project_root()
  out <- tempfile("mimic_out_")
  old <- setwd(root); on.exit(setwd(old), add = TRUE)
  res <- system2("Rscript", c("mimic/run_mimic_ckd.R", "tests/fixtures/mimic_mini", out),
                 stdout = TRUE, stderr = TRUE)
  expect_true(file.exists(file.path(out, "mimic_ckd_patients.csv")))

  p <- fread(file.path(out, "mimic_ckd_patients.csv"))
  expect_setequal(p[meets_kdigo == TRUE, subject_id], c(1, 2, 3, 6))
  expect_setequal(p[meets_hybrid == TRUE, subject_id], c(1, 2, 5, 6))
  expect_setequal(p[has_ckd_code == TRUE, subject_id], c(2, 6))   # ICD-10 N18.31 and ICD-9 585.3

  packet <- fread(file.path(out, "nephrology_review_packet.csv"))
  expect_setequal(packet$subject_id, c(1, 3, 5))                   # patient 3 is the AKI-only pattern
})
