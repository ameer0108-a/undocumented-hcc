# step_40_rules_r.R
# Runs the R version of the rules on every scenario and writes study.rule_flag_r.

Sys.setenv(TZ = "UTC")
source("R/utils.R"); source("R/rules.R")

sp <- study_params()
con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)
q <- function(sql) as.data.table(DBI::dbGetQuery(con, sql))

cohort <- q("select patient_id, birth_date, sex from study.cohort")
cohort[, birth_date := as.IDate(birth_date)]
dm_med <- q("select patient_id from study.dm_med")
labs   <- q("select scenario, draw_id, patient_id, lab, draw_ts, draw_date, setting, value
             from study.lab_value")
labs[, draw_date := as.IDate(draw_date)]

flags <- rbindlist(lapply(split(labs, by = "scenario"), function(l) {
  cbind(scenario = l$scenario[1], apply_rules(l, cohort, dm_med, sp))
}))

invisible(DBI::dbExecute(con, "DROP TABLE IF EXISTS study.rule_flag_r CASCADE"))
invisible(DBI::dbWriteTable(con, c("study", "rule_flag_r"), as.data.frame(flags), row.names = FALSE))
invisible(DBI::dbExecute(con, "CREATE INDEX ON study.rule_flag_r (scenario, patient_id, hcc)"))
cat("step 40 done:", nrow(flags), "flag rows written\n")
