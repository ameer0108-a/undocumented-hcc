root <- project_root()
xw  <- fread(file.path(root, "reference", "snomed_icd10cm_crosswalk.csv"), colClasses = "character")
cms <- fread(file.path(root, "reference", "cms_v28_dx_to_hcc_2026.csv"), colClasses = c("character", "integer"))
hcc_of <- function(icd) sort(cms[icd10cm == gsub(".", "", icd, fixed = TRUE), hcc])

test_that("every SNOMED code maps to exactly one ICD-10-CM code", {
  expect_equal(anyDuplicated(xw$snomed_code), 0L)
  expect_true(all(nzchar(xw$icd10cm)))
  expect_true(all(grepl("^[A-Z][0-9][0-9A-Z](\\.[0-9A-Z]{1,4})?$", xw$icd10cm)))
})

test_that("kidney codes land in the right V28 HCCs", {
  expect_equal(hcc_of("N18.30"), 329L)
  expect_equal(hcc_of("N18.31"), 329L)
  expect_equal(hcc_of("N18.32"), 328L)
  expect_equal(hcc_of("N18.4"), 327L)
  expect_equal(hcc_of("N18.6"), 326L)
  expect_length(hcc_of("N18.2"), 0)   # stage 2 carries no payment HCC in V28
})

test_that("diabetes codes land in the diabetes family", {
  expect_equal(hcc_of("E11.9"), 38L)
  expect_equal(hcc_of("E11.21"), 37L)
  expect_equal(hcc_of("E11.40"), 37L)
})

test_that("V28 coefficients for the four target HCCs are the published values", {
  co <- v28_coef()
  expect_equal(unname(co[c("38", "329", "328", "327")]), c(0.166, 0.127, 0.127, 0.514))
})
