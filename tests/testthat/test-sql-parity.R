# These tests need the project database. They are skipped if it isn't reachable.

test_that("SQL and R eGFR agree to the last bit on a grid of inputs", {
  skip_if_not(db_available(), "database not reachable")
  con <- db_connect(); on.exit(DBI::dbDisconnect(con))
  grid <- CJ(scr = c(0.45, 0.7, 0.9, 1.13, 1.6, 2.37, 4.8), age = c(65L, 79L, 101L), sex = c("F", "M"))
  sql <- sprintf("select ref.egfr_ckd_epi_2021(%s::float8, %d, '%s') as e", grid$scr, grid$age, grid$sex)
  sql_vals <- vapply(sql, function(s) DBI::dbGetQuery(con, s)$e, numeric(1))
  expect_identical(unname(sql_vals), egfr_ckd_epi_2021(grid$scr, grid$age, grid$sex))
})

test_that("SQL and R age calculations agree, including leap-day birthdays", {
  skip_if_not(db_available(), "database not reachable")
  con <- db_connect(); on.exit(DBI::dbDisconnect(con))
  cases <- data.table(d = c("2025-02-28", "2025-03-01", "2024-02-29", "2025-12-31"),
                      b = c("1960-02-29", "1960-02-29", "1940-02-29", "1950-12-31"))
  sql_age <- vapply(seq_len(nrow(cases)), function(i)
    DBI::dbGetQuery(con, sprintf("select date_part('year', age('%s'::date, '%s'::date))::int as a",
                                 cases$d[i], cases$b[i]))$a, integer(1))
  expect_equal(sql_age, age_on(cases$d, cases$b))
})

test_that("SQL and R HCC staging agree at the boundaries", {
  skip_if_not(db_available(), "database not reachable")
  con <- db_connect(); on.exit(DBI::dbDisconnect(con))
  vals <- c(60, 59.9999, 45, 44.9999, 30, 29.9999, 14)
  sql <- vapply(vals, function(v) {
    r <- DBI::dbGetQuery(con, sprintf("select ref.hcc_from_egfr(%s::float8) as h", format(v, digits = 15)))$h
    if (is.na(r)) NA_integer_ else as.integer(r)
  }, integer(1))
  expect_equal(sql, hcc_from_egfr(vals))
})

test_that("every pipeline pair agrees between SQL and R", {
  skip_if_not(db_available(), "database not reachable")
  con <- db_connect(); on.exit(DBI::dbDisconnect(con))
  has <- DBI::dbGetQuery(con, "select to_regclass('study.rule_flag_r') is not null as ok")$ok
  skip_if_not(isTRUE(has), "pipeline has not been run yet")
  d <- DBI::dbGetQuery(con, "
    select count(*) as n from study.rule_flag_sql s
    full join study.rule_flag_r r using (scenario, patient_id, hcc)
    where s.t1 is distinct from r.t1 or s.t2 is distinct from r.t2 or s.t3 is distinct from r.t3")
  expect_equal(as.integer(d$n), 0L)
})
