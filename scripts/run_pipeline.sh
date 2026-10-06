#!/usr/bin/env bash
# Runs the whole analysis on a database that build_database.sh already filled.
#
# Usage:  scripts/run_pipeline.sh
# Uses the normal PG* environment variables. Takes about 10 minutes on a laptop.

set -euo pipefail
cd "$(dirname "$0")/.."
export PGHOST=${PGHOST:-localhost} PGUSER=${PGUSER:-ehr} PGDATABASE=${PGDATABASE:-ehr}
export TZ=UTC
mkdir -p output/tables output/figures output/logs

run_sql() { echo "  sql/$1"; psql -q -v ON_ERROR_STOP=1 -f "sql/$1"; }
run_r()   { echo "  R/$1";   Rscript "R/$1"; }

echo "1. Reference tables"
run_sql 10_reference.sql
psql -q -v ON_ERROR_STOP=1 <<'EOF'
\copy ref.study_params     FROM 'config/study_params.csv'      WITH (FORMAT csv, HEADER true)
\copy ref.lab_model_params FROM 'config/lab_model_params.csv'  WITH (FORMAT csv, HEADER true)
\copy ref.snomed_icd10cm   FROM 'reference/snomed_icd10cm_crosswalk.csv' WITH (FORMAT csv, HEADER true)
\copy ref.v28_dx_to_hcc    FROM 'reference/cms_v28_dx_to_hcc_2026.csv'   WITH (FORMAT csv, HEADER true)
\copy ref.v28_labels       FROM 'reference/cms_v28_hcc_labels.csv'       WITH (FORMAT csv, HEADER true)
\copy ref.v28_hierarchy    FROM 'reference/cms_v28_hierarchies.csv'      WITH (FORMAT csv, HEADER true)
\copy ref.v28_coefficient  FROM 'reference/cms_v28_coefficients_cna.csv' WITH (FORMAT csv, HEADER true)
EOF

echo "2. Cohort, crosswalk, truth, lab draws"
run_sql 11_cohort.sql
run_sql 12_crosswalk.sql
run_sql 13_truth.sql
run_sql 14_lab_draws.sql

echo "3. Masking and lab model"
run_r step_20_mask_and_labs.R

echo "4. Rules in SQL, then in R"
run_sql 30_rules.sql
run_r step_40_rules_r.R

echo "5. Evaluation, reconciliation, figures"
run_r step_50_evaluate.R
run_r step_60_reconcile.R
run_r step_70_figures.R

echo "6. Unit tests"
Rscript -e 'testthat::test_dir("tests/testthat", stop_on_failure = TRUE)'

echo "Done. Tables are in output/tables, figures in output/figures."
