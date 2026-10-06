# score_review.R
# After a nephrologist fills in nephrology_review_packet.csv, this scores it.
# PPV here means: of the flagged patients with no CKD code, how many did the reviewer
# agree actually have CKD. It is reported separately for the KDIGO rule and the hybrid.
#
# Usage: Rscript mimic/score_review.R mimic/output/nephrology_review_packet_completed.csv mimic/output/mimic_ckd_patients.csv

source("R/utils.R")
args <- commandArgs(trailingOnly = TRUE)
rev <- fread(args[1])
pts <- fread(args[2])[, .(subject_id, meets_kdigo, meets_hybrid)]
rev <- merge(rev, pts, by = "subject_id")
rev <- rev[toupper(reviewer_ckd_present) %in% c("Y", "N")]
if (nrow(rev) == 0) stop("No reviewed rows yet. reviewer_ckd_present should be Y or N.")
rev[, agree := toupper(reviewer_ckd_present) == "Y"]

score_one <- function(x, label) {
  ci <- wilson_ci(sum(x$agree), nrow(x))
  data.table(rule = label, reviewed = nrow(x), reviewer_confirmed = sum(x$agree),
             ppv = round(ci$est, 2), ci_95 = sprintf("%.2f to %.2f", ci$lo, ci$hi))
}
out <- rbind(score_one(rev[meets_kdigo == TRUE], "KDIGO (any setting)"),
             score_one(rev[meets_hybrid == TRUE], "Revalidation hybrid (outpatient)"))
print(out)
fwrite(out, sub("\\.csv$", "_scored.csv", args[1]))

# Reasons the reviewer gave for "no" are the best clue for the next rule change
print(rev[agree == FALSE, .N, by = reviewer_reason_if_no][order(-N)])
