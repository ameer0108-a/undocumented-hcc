# step_20_mask_and_labs.R
# 1. Masks documentation for a random share of true diabetes and CKD cases.
# 2. Builds the lab values for every scenario and writes them to study.lab_value.
#
# Scenarios written:
#   raw              Synthea's own values, every draw
#   model_complete   lab model values, every draw (no missing tests)
#   calibrated       lab model values with missing tests (the main analysis)
#   sens_egfr_sd10   calibrated, but people without CKD sit closer to eGFR 60
#   sens_egfr_sd20   calibrated, but people without CKD are spread further above 60

Sys.setenv(TZ = "UTC")
source("R/utils.R"); source("R/mask.R"); source("R/lab_model.R")

sp <- study_params()
lp <- lab_params()
con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)

q <- function(sql) as.data.table(DBI::dbGetQuery(con, sql))

cohort <- q("select patient_id, birth_date, sex, age from study.cohort")
truth  <- q("select * from study.truth")
draws  <- q("select draw_id, patient_id, lab, draw_ts, draw_date, setting, encounter_class, synthea_value
             from study.lab_draw")
draws[, draw_date := as.IDate(draw_date)]

# ---------------------------------------------------------------- masking
masks <- make_masks(truth, sp$mask_rate_dm, sp$mask_rate_ckd, sp$seed)
documented <- documented_after_mask(truth, masks)
cat(sprintf("Masked %d of %d diabetes cases and %d of %d in-scope CKD cases\n",
            masks[family == "DM", sum(masked)], masks[family == "DM", .N],
            masks[family == "CKD", sum(masked)], masks[family == "CKD", .N]))

# ---------------------------------------------------------------- lab model
pts <- merge(cohort, truth[, .(patient_id, dm_true, prediabetes, ckd_stage_coded)], by = "patient_id")
main <- build_lab_values(draws, pts, sp, lp)
print(main$calibration)

lp10 <- modifyList(lp, list(egfr_nockd_halfnormal_sd = 10))
lp20 <- modifyList(lp, list(egfr_nockd_halfnormal_sd = 20))
s10 <- build_lab_values(draws, pts, sp, lp10)
s20 <- build_lab_values(draws, pts, sp, lp20)

cols <- c("draw_id", "patient_id", "lab", "draw_ts", "draw_date", "setting")
lab_value <- rbindlist(list(
  main$draws[, c(.(scenario = "raw"), .SD, .(value = synthea_value)), .SDcols = cols],
  main$draws[, c(.(scenario = "model_complete"), .SD, .(value = model_value)), .SDcols = cols],
  main$draws[kept == TRUE, c(.(scenario = "calibrated"), .SD, .(value = model_value)), .SDcols = cols],
  s10$draws[kept == TRUE, c(.(scenario = "sens_egfr_sd10"), .SD, .(value = model_value)), .SDcols = cols],
  s20$draws[kept == TRUE, c(.(scenario = "sens_egfr_sd20"), .SD, .(value = model_value)), .SDcols = cols]
))
lab_value[, draw_date := as.Date(draw_date)]

calibration <- rbindlist(list(
  cbind(scenario = "calibrated", main$calibration),
  cbind(scenario = "sens_egfr_sd10", s10$calibration),
  cbind(scenario = "sens_egfr_sd20", s20$calibration)
))
latent <- main$latent[, .(patient_id, a1c_mu, egfr_true, scr_true, latent_hcc)]
aki <- main$draws[lab == "creatinine", .(n_creatinine_draws = .N, n_acute = sum(setting == "acute"),
                                         n_aki_spikes = sum(aki_spike))]
print(aki)

# ---------------------------------------------------------------- write
write_tbl <- function(name, x) invisible({
  DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS study.%s CASCADE", name))
  DBI::dbWriteTable(con, c("study", name), as.data.frame(x), row.names = FALSE)
})
write_tbl("mask", masks)
write_tbl("documented", documented)
write_tbl("lab_latent", latent)
write_tbl("lab_calibration", calibration)
write_tbl("lab_value", lab_value)
invisible(DBI::dbExecute(con, "ALTER TABLE study.lab_value
                       ALTER COLUMN draw_date TYPE date USING draw_date::date,
                       ALTER COLUMN draw_ts TYPE timestamptz USING draw_ts::timestamptz"))
invisible(DBI::dbExecute(con, "CREATE INDEX ON study.lab_value (scenario, lab, patient_id)"))
invisible(DBI::dbExecute(con, "ANALYZE study.lab_value"))

dir.create("output/tables", showWarnings = FALSE, recursive = TRUE)
fwrite(calibration, "output/tables/lab_missingness_calibration.csv")
fwrite(aki, "output/tables/lab_aki_spikes.csv")
cat("step 20 done:", nrow(lab_value), "lab rows written\n")
