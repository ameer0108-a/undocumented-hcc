sp <- test_params()

# one 75-year-old man; creatinine values are built backwards from the eGFR we want
pt <- data.table(patient_id = 1:20, birth_date = as.IDate("1950-01-01"), sex = "M")
cr_for <- function(egfr, date) round(scr_from_egfr(egfr, age_on(date, "1950-01-01"), "M"), 4)
ckd_rows <- function(id, dates, egfrs, setting = "outpatient") {
  x <- lab_rows(id, "creatinine", dates, mapply(cr_for, egfrs, dates), setting)
  x[, draw_id := seq_len(.N) + 1000L * id]
  x
}
run <- function(labs) {
  labs <- copy(labs)
  if (!"draw_id" %in% names(labs)) labs[, draw_id := .I]
  rules_ckd(labs, pt, sp)
}
flag <- function(out, id, tier) out[patient_id == id][[paste0("hcc_", tier)]]

test_that("89 days apart is not chronic; 90 days is", {
  out <- run(rbind(ckd_rows(1L, c("2025-01-01", "2025-03-31"), c(50, 50)),
                   ckd_rows(2L, c("2025-01-01", "2025-04-01"), c(50, 50))))
  expect_equal(flag(out, 1, "t1"), 329L)
  expect_true(is.na(flag(out, 1, "t2")))
  expect_equal(flag(out, 2, "t2"), 329L)
})

test_that("a low value in the hospital is ignored by the hybrid", {
  labs <- rbind(ckd_rows(3L, "2025-02-01", 25, "acute"),
                ckd_rows(3L, c("2025-03-01", "2025-09-01"), c(75, 78)))
  out <- run(labs)
  expect_equal(flag(out, 3, "t1"), 327L)
  expect_true(is.na(flag(out, 3, "t3")))
})

test_that("chronic low values do not alert under the hybrid if the latest outpatient value recovered", {
  out <- run(ckd_rows(4L, c("2024-03-01", "2024-09-01", "2025-06-01"), c(52, 50, 68)))
  expect_equal(flag(out, 4, "t2"), 329L)
  expect_true(is.na(flag(out, 4, "t3")))
})

test_that("one low value plus albuminuria re-validates if the latest value is still low", {
  labs <- rbind(ckd_rows(5L, c("2025-05-01", "2025-06-15"), c(70, 48)),
                lab_rows(5L, "uacr", "2025-05-01", 45), fill = TRUE)
  out <- run(labs)
  expect_true(is.na(flag(out, 5, "t2")))
  expect_equal(flag(out, 5, "t3"), 329L)
})

test_that("guideline tier stages by the median low value, single lab by the worst", {
  out <- run(ckd_rows(6L, c("2024-02-01", "2024-08-01", "2025-02-01"), c(50, 40, 35)))
  expect_equal(flag(out, 6, "t1"), 328L)             # worst is 35 -> 328
  expect_equal(flag(out, 6, "t2"), 328L)             # median is 40 -> 328
  out2 <- run(ckd_rows(7L, c("2024-02-01", "2024-08-01"), c(50, 25)))
  expect_equal(flag(out2, 7, "t1"), 327L)
  expect_equal(flag(out2, 7, "t2"), 328L)            # median of 50 and 25 is 37.5
})

test_that("the latest outpatient draw wins when two land on the same day", {
  labs <- ckd_rows(8L, c("2024-02-01", "2025-01-10", "2025-01-10"), c(50, 55, 70))
  labs[3, draw_ts := draw_ts + 3600]   # the normal result came back an hour later
  out <- run(labs)
  expect_true(is.na(flag(out, 8, "t3")))
})
