# Checks on the ground-truth tables. Need the database and a finished pipeline run.

pipeline_ready <- function() {
  if (!db_available()) return(FALSE)
  con <- db_connect(); on.exit(DBI::dbDisconnect(con))
  isTRUE(DBI::dbGetQuery(con, "select to_regclass('study.mask') is not null as ok")$ok)
}

test_that("diabetes truth comes from a diabetes diagnosis, not from 'due to diabetes' kidney codes", {
  skip_if_not(pipeline_ready(), "pipeline has not been run yet")
  con <- db_connect(); on.exit(DBI::dbDisconnect(con))
  n <- DBI::dbGetQuery(con, "
    select count(*) as n from study.truth t
    where t.dm_true and not exists (
      select 1 from study.condition_mapped m
      where m.patient_id = t.patient_id and m.snomed_code = '44054006')")$n
  expect_equal(as.integer(n), 0L)
  both <- DBI::dbGetQuery(con, "select count(*) as n from study.truth where dm_true and dm_code_artifact")$n
  expect_equal(as.integer(both), 0L)
})

test_that("only true, in-scope cases are ever masked", {
  skip_if_not(pipeline_ready(), "pipeline has not been run yet")
  con <- db_connect(); on.exit(DBI::dbDisconnect(con))
  bad <- DBI::dbGetQuery(con, "
    select count(*) as n from study.mask m join study.truth t using (patient_id)
    where (m.family = 'DM' and not t.dm_true)
       or (m.family = 'CKD' and (t.ckd_hcc is null or t.ckd_hcc = 326))")$n
  expect_equal(as.integer(bad), 0L)
})
