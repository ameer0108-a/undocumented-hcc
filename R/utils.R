# utils.R
# Small helpers shared by every R script and by the tests.
# Nothing in here touches the database except db_connect().

suppressPackageStartupMessages({
  library(data.table)
})

project_root <- function() {
  # Works whether a script is run from the repo root or from tests/testthat
  d <- normalizePath(getwd())
  while (!file.exists(file.path(d, "config", "study_params.csv"))) {
    parent <- dirname(d)
    if (parent == d) stop("Could not find the project root (config/study_params.csv).")
    d <- parent
  }
  d
}

db_connect <- function() {
  suppressPackageStartupMessages(library(RPostgreSQL))
  DBI::dbConnect(
    DBI::dbDriver("PostgreSQL"),
    host = Sys.getenv("PGHOST", "localhost"),
    port = as.integer(Sys.getenv("PGPORT", "5432")),
    dbname = Sys.getenv("PGDATABASE", "ehr"),
    user = Sys.getenv("PGUSER", "ehr"),
    password = Sys.getenv("PGPASSWORD", "")
  )
}

# Reads a key,value csv into a named list. Numbers come back as numbers.
read_params <- function(file) {
  p <- fread(file, colClasses = "character")
  out <- as.list(p$value)
  names(out) <- p$key
  lapply(out, function(v) {
    num <- suppressWarnings(as.numeric(v))
    if (!is.na(num) && grepl("^-?[0-9.]+$", v)) num else v
  })
}

study_params <- function() read_params(file.path(project_root(), "config", "study_params.csv"))
lab_params   <- function() read_params(file.path(project_root(), "config", "lab_model_params.csv"))

# ---------------------------------------------------------------- kidney function

# CKD-EPI 2021 creatinine equation (race-free). Inker et al., NEJM 2021.
# scr in mg/dL, age in years, sex "F" or "M". Returns mL/min/1.73m2.
egfr_ckd_epi_2021 <- function(scr, age, sex) {
  female <- sex == "F"
  kappa  <- ifelse(female, 0.7, 0.9)
  alpha  <- ifelse(female, -0.241, -0.302)
  ratio  <- scr / kappa
  142 * pmin(ratio, 1)^alpha * pmax(ratio, 1)^(-1.200) * 0.9938^age * ifelse(female, 1.012, 1)
}

# Inverse of the equation above: what creatinine gives this eGFR for this person.
# Used only by the lab model to turn a latent eGFR into a creatinine value.
scr_from_egfr <- function(egfr, age, sex) {
  female <- sex == "F"
  kappa  <- ifelse(female, 0.7, 0.9)
  alpha  <- ifelse(female, -0.241, -0.302)
  base   <- 142 * 0.9938^age * ifelse(female, 1.012, 1)
  x      <- egfr / base
  # x >= 1 means creatinine is at or below kappa, so the alpha branch applies
  ifelse(x >= 1, kappa * x^(1 / alpha), kappa * x^(1 / -1.200))
}

# KDIGO GFR category for a single value
egfr_category <- function(egfr) {
  cut(egfr, breaks = c(-Inf, 15, 30, 45, 60, 90, Inf), right = FALSE,
      labels = c("G5", "G4", "G3b", "G3a", "G2", "G1"))
}

# V28 kidney HCC implied by an eGFR value. Anything under 30 is credited as HCC 327:
# stage 5 belongs to the ESRD model and is out of scope here.
hcc_from_egfr <- function(egfr) {
  data.table::fcase(
    is.na(egfr), NA_integer_,
    egfr >= 60, NA_integer_,
    egfr >= 45, 329L,
    egfr >= 30, 328L,
    default = 327L
  )
}

# Completed years of age on a given date. Matches PostgreSQL date_part('year', age(d, b)).
age_on <- function(d, birth) {
  d <- as.IDate(d); birth <- as.IDate(birth)
  yrs <- year(d) - year(birth)
  before_bday <- (month(d) < month(birth)) | (month(d) == month(birth) & mday(d) < mday(birth))
  yrs - as.integer(before_bday)
}

# ---------------------------------------------------------------- statistics

# Wilson score interval for a binomial proportion
wilson_ci <- function(x, n, conf = 0.95) {
  z <- qnorm(1 - (1 - conf) / 2)
  p <- ifelse(n > 0, x / n, NA_real_)
  denom  <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / denom
  half   <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom
  list(est = p, lo = pmax(0, centre - half), hi = pmin(1, centre + half))
}

fmt_ci <- function(est, lo, hi, digits = 2) {
  sprintf(paste0("%.", digits, "f (%.", digits, "f to %.", digits, "f)"), est, lo, hi)
}

# V28 community, non-dual, aged coefficients for the HCCs used here
v28_coef <- function() {
  co <- fread(file.path(project_root(), "reference", "cms_v28_coefficients_cna.csv"))
  setNames(co$coefficient, co$hcc)
}
