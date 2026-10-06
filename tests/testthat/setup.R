# Loaded automatically by testthat before the test files run.
Sys.setenv(TZ = "UTC")
root <- normalizePath(file.path(getwd(), "..", ".."))
old <- setwd(root)
source("R/utils.R"); source("R/mask.R"); source("R/lab_model.R"); source("R/rules.R"); source("R/evaluate.R")
setwd(old)

# Small helper so rule tests read like a story
lab_rows <- function(patient_id, lab, dates, values, setting = "outpatient") {
  n <- length(values)
  data.table(patient_id = patient_id, lab = lab, draw_date = as.IDate(dates),
             draw_ts = as.POSIXct(paste(dates, "09:00:00"), tz = "UTC"),
             setting = rep_len(setting, n), value = values)
}
test_params <- function() {
  list(a1c_threshold = 6.5, egfr_threshold = 60, kdigo_min_days = 90, uacr_threshold = 30)
}

db_available <- function() {
  ok <- tryCatch({ con <- db_connect(); DBI::dbDisconnect(con); TRUE }, error = function(e) FALSE)
  ok
}
