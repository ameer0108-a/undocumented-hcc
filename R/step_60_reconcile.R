# step_60_reconcile.R
# Compares the SQL and R rule outputs pair by pair (patient x target HCC) for every scenario.
# A pair is concordant only if all three tier flags match.
# Any disagreement is written out with the underlying lab values so it can be traced.

Sys.setenv(TZ = "UTC")
source("R/utils.R")

con <- db_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)
q <- function(sql) as.data.table(DBI::dbGetQuery(con, sql))

cmp <- q("
  select s.scenario, s.patient_id, s.hcc,
         s.t1 as sql_t1, r.t1 as r_t1, s.t2 as sql_t2, r.t2 as r_t2, s.t3 as sql_t3, r.t3 as r_t3
  from study.rule_flag_sql s
  full join study.rule_flag_r r using (scenario, patient_id, hcc)")

cmp[, missing_side := is.na(sql_t1) | is.na(r_t1)]
cmp[, concordant := !missing_side & sql_t1 == r_t1 & sql_t2 == r_t2 & sql_t3 == r_t3]

summary <- cmp[, .(
  pairs        = .N,
  concordant   = sum(concordant),
  discordant   = sum(!concordant),
  pct          = round(100 * mean(concordant), 3),
  t1_disagree  = sum(sql_t1 != r_t1, na.rm = TRUE),
  t2_disagree  = sum(sql_t2 != r_t2, na.rm = TRUE),
  t3_disagree  = sum(sql_t3 != r_t3, na.rm = TRUE),
  missing_rows = sum(missing_side)
), by = scenario]
print(summary)
fwrite(summary, "output/tables/reconciliation_summary.csv")

# How much did the numeric-literal version of the SQL eGFR function differ on real inputs?
literal_check <- q("
  select l.scenario,
         count(*) as creatinine_draws,
         sum((a.e_new <> a.e_old)::int) as draws_with_any_difference,
         max(abs(a.e_new - a.e_old)) as max_abs_difference,
         sum(((a.e_new < 60) <> (a.e_old < 60))::int) as threshold_flips,
         sum((ref.hcc_from_egfr(a.e_new) is distinct from ref.hcc_from_egfr(a.e_old))::int) as stage_flips
  from study.lab_value l
  join study.cohort c using (patient_id)
  cross join lateral (
    select ref.egfr_ckd_epi_2021(l.value, date_part('year', age(l.draw_date, c.birth_date))::int, c.sex) as e_new,
           ref.egfr_ckd_epi_2021_numeric_literals(l.value, date_part('year', age(l.draw_date, c.birth_date))::int, c.sex) as e_old
  ) a
  where l.lab = 'creatinine'
  group by l.scenario order by l.scenario")
print(literal_check)
fwrite(literal_check, "output/tables/reconciliation_numeric_literal_impact.csv")

bad <- cmp[concordant == FALSE]
fwrite(bad, "output/tables/reconciliation_discordant_pairs.csv")
if (nrow(bad) > 0) {
  cat(nrow(bad), "discordant pairs. First few:\n")
  print(head(bad, 20))
}
cat("step 60 done\n")
