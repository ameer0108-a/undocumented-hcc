# run_mimic_ckd.R
# Applies the same KDIGO kidney rules to MIMIC-IV (real hospital data) and asks one question:
# of the patients whose labs meet CKD criteria, how many have no CKD diagnosis code anywhere?
#
# Works on the free MIMIC-IV Clinical Database Demo (100 patients, open access) and,
# unchanged, on the full credentialed MIMIC-IV hosp module.
#
# Usage (from the repo root):
#   Rscript mimic/run_mimic_ckd.R path/to/mimic-iv-clinical-database-demo-2.2
# The folder must contain hosp/patients.csv.gz, hosp/labevents.csv.gz, hosp/d_labitems.csv.gz,
# hosp/diagnoses_icd.csv.gz. Nothing is written back into that folder.
#
# Data use note: the demo is open data. The full MIMIC-IV is not. If you ever get credentialed
# access, run this on your own machine and never paste rows into an AI tool or share them.

Sys.setenv(TZ = "UTC")
source("R/utils.R")

args <- commandArgs(trailingOnly = TRUE)
mimic_dir <- if (length(args) >= 1) args[1] else "mimic/data/mimic-iv-clinical-database-demo-2.2"
out_dir   <- if (length(args) >= 2) args[2] else "mimic/output"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
hosp <- function(f) file.path(mimic_dir, "hosp", f)
stopifnot(file.exists(hosp("labevents.csv.gz")))

sp <- study_params()
MIN_AGE <- 18   # MIMIC is an adult hospital population; Medicare age is reported as a subgroup

# ---------------------------------------------------------------- load
patients <- fread(hosp("patients.csv.gz"), select = c("subject_id", "gender", "anchor_age", "anchor_year"))
items    <- fread(hosp("d_labitems.csv.gz"))
dx       <- fread(hosp("diagnoses_icd.csv.gz"), select = c("subject_id", "hadm_id", "icd_code", "icd_version"),
                  colClasses = list(character = "icd_code"))

# Lab items are picked by name and fluid, not hard-coded itemids, so the same script works across versions
cr_items  <- items[tolower(label) == "creatinine" & tolower(fluid) == "blood", itemid]
acr_items <- items[grepl("albumin/creatinine", tolower(label)) & tolower(fluid) == "urine", itemid]
cat("creatinine itemids:", cr_items, " uACR itemids:", acr_items, "\n")

labs <- fread(hosp("labevents.csv.gz"),
              select = c("subject_id", "hadm_id", "itemid", "charttime", "valuenum", "valueuom"))
labs <- labs[itemid %in% c(cr_items, acr_items) & !is.na(valuenum)]
labs[, lab := fifelse(itemid %in% cr_items, "creatinine", "uacr")]
# A few results are stored twice at the same chart time. Keep one per patient, lab and time.
labs <- unique(labs, by = c("subject_id", "lab", "charttime"))
labs[, draw_ts := as.POSIXct(charttime, tz = "UTC")]
labs[, draw_date := as.IDate(draw_ts)]
# In MIMIC, a lab with a hospital admission id was drawn during a stay. Everything else is outpatient.
labs[, setting := fifelse(is.na(hadm_id), "outpatient", "acute")]
labs[, draw_id := .I]

# ---------------------------------------------------------------- eGFR
cr <- merge(labs[lab == "creatinine"], patients, by = "subject_id")
# MIMIC gives age at an anchor year; dates are shifted, but intervals within a patient are real
cr[, age := anchor_age + (year(draw_date) - anchor_year)]
cr <- cr[age >= MIN_AGE & valuenum > 0]
cr[, egfr := egfr_ckd_epi_2021(valuenum, age, gender)]

# ---------------------------------------------------------------- CKD codes anywhere in the record
ckd_icd10 <- "^(N18|I12|I13|E0[89]22|E1[013]22|Z992|Z49)"
ckd_icd9  <- "^(585|403|404|V4511|V56)"
ckd_coded <- unique(dx[(icd_version == 10 & grepl(ckd_icd10, icd_code)) |
                         (icd_version == 9 & grepl(ckd_icd9, icd_code)), .(subject_id)])
ckd_coded[, has_ckd_code := TRUE]

# ---------------------------------------------------------------- rules (same logic as R/rules.R)
low <- cr[egfr < sp$egfr_threshold]
kdigo <- low[, .(n_low = .N, span_days = as.integer(max(draw_date) - min(draw_date)),
                 egfr_median_low = median(egfr), egfr_min = min(egfr)), by = subject_id]
kdigo[, meets_kdigo := span_days >= sp$kdigo_min_days]

op <- cr[setting == "outpatient"]
setorder(op, subject_id, draw_ts, draw_id)
last_op <- op[, .SD[.N], by = subject_id][, .(subject_id, last_outpatient_egfr = egfr)]
op_low <- op[egfr < sp$egfr_threshold, .(op_span = as.integer(max(draw_date) - min(draw_date)),
                                         op_median_low = median(egfr)), by = subject_id]
alb <- unique(labs[lab == "uacr" & valuenum >= sp$uacr_threshold, .(subject_id)])[, albuminuria := TRUE]

res <- merge(patients[, .(subject_id, gender, anchor_age)], kdigo, by = "subject_id", all.x = TRUE)
res <- merge(res, op_low, by = "subject_id", all.x = TRUE)
res <- merge(res, last_op, by = "subject_id", all.x = TRUE)
res <- merge(res, alb, by = "subject_id", all.x = TRUE)
res <- merge(res, ckd_coded, by = "subject_id", all.x = TRUE)
res[is.na(meets_kdigo), meets_kdigo := FALSE]
res[is.na(albuminuria), albuminuria := FALSE]
res[is.na(has_ckd_code), has_ckd_code := FALSE]
res[, meets_hybrid := !is.na(op_span) & (op_span >= sp$kdigo_min_days | albuminuria) &
                      !is.na(last_outpatient_egfr) & last_outpatient_egfr < sp$egfr_threshold]
res[, lab_stage_hcc := hcc_from_egfr(egfr_median_low)]
res[, medicare_age := anchor_age >= 65]

# ---------------------------------------------------------------- summary
summ <- function(x, label) {
  n <- nrow(x); k <- sum(!x$has_ckd_code); ci <- wilson_ci(k, n)
  data.table(group = label, patients_meeting_criteria = n, without_ckd_code = k,
             pct_without_code = round(100 * ci$est, 1),
             ci_95 = sprintf("%.1f to %.1f", 100 * ci$lo, 100 * ci$hi))
}
summary <- rbind(
  data.table(group = "Patients in the dataset", patients_meeting_criteria = nrow(patients),
             without_ckd_code = NA, pct_without_code = NA, ci_95 = NA),
  data.table(group = "Patients with any creatinine", patients_meeting_criteria = uniqueN(cr$subject_id),
             without_ckd_code = NA, pct_without_code = NA, ci_95 = NA),
  summ(res[meets_kdigo == TRUE], "Meets KDIGO lab criteria (any setting)"),
  summ(res[meets_kdigo == TRUE & medicare_age == TRUE], "Meets KDIGO, age 65+ at anchor"),
  summ(res[meets_hybrid == TRUE], "Meets revalidation hybrid (outpatient only)")
)
print(summary)
fwrite(summary, file.path(out_dir, "mimic_ckd_summary.csv"))

# Patient-level output. The demo is open data, so this file is safe to keep in the repo.
# For full MIMIC-IV, keep it on your own machine.
fwrite(res[meets_kdigo == TRUE | meets_hybrid == TRUE][order(has_ckd_code, egfr_median_low)],
       file.path(out_dir, "mimic_ckd_patients.csv"))

# ---------------------------------------------------------------- review packet
# One row per flagged patient with no CKD code. A nephrologist fills in the last four columns.
packet <- res[(meets_kdigo | meets_hybrid) & !has_ckd_code,
              .(subject_id, gender, anchor_age, n_low_egfr_values = n_low, days_between_first_and_last_low = span_days,
                lowest_egfr = round(egfr_min, 1), median_low_egfr = round(egfr_median_low, 1),
                last_outpatient_egfr = round(last_outpatient_egfr, 1), albuminuria,
                rule_suggested_stage = fcase(lab_stage_hcc == 329L, "G3a", lab_stage_hcc == 328L, "G3b",
                                             lab_stage_hcc == 327L, "G4 or worse", default = ""),
                reviewer_ckd_present = "", reviewer_stage = "", reviewer_reason_if_no = "", reviewer_initials = "")]
# Acute kidney injury codes are the most likely reason a flagged patient has no CKD code, so show them
aki <- dx[(icd_version == 10 & grepl("^N17", icd_code)) | (icd_version == 9 & grepl("^584", icd_code)),
          .(aki_codes_in_record = paste(sort(unique(icd_code)), collapse = " ")), by = subject_id]
packet <- merge(packet, aki, by = "subject_id", all.x = TRUE)
packet[is.na(aki_codes_in_record), aki_codes_in_record := ""]
setcolorder(packet, c(setdiff(names(packet), grep("^reviewer_", names(packet), value = TRUE)),
                      grep("^reviewer_", names(packet), value = TRUE)))
fwrite(packet, file.path(out_dir, "nephrology_review_packet.csv"))
cat("Wrote", nrow(packet), "rows to the review packet\n")
