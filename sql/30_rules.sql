-- 30_rules.sql
-- SQL version of the detection rules. R/rules.R is the R version; step 60 compares them.
-- Runs every scenario in study.lab_value at once and writes study.rule_flag_sql:
-- one row per scenario x cohort patient x target HCC, with a flag for each tier.
--
--   t1 single lab   one abnormal result in the window
--   t2 guideline    ADA: 2 abnormal HbA1c on different days
--                   KDIGO: 2 eGFR < 60 at least 90 days apart
--   t3 revalidation DM: t2, or t1 plus a glucose-lowering drug
--      hybrid       CKD: outpatient draws only; chronicity or (one low eGFR + uACR >= 30);
--                   and the latest outpatient eGFR is still < 60

SET client_min_messages = warning;

-- Every constant is cast to float8 on purpose. Bare literals like 0.9938 are type numeric
-- in PostgreSQL, so power(0.9938, age) runs in exact decimal math and the result drifts
-- from R in the last few bits. The parity test in tests/testthat/test-sql-parity.R caught this.
CREATE OR REPLACE FUNCTION ref.egfr_ckd_epi_2021(scr double precision, age_years integer, sex text)
RETURNS double precision LANGUAGE sql IMMUTABLE AS $$
  SELECT 142::float8
         * power(least(scr / CASE WHEN sex = 'F' THEN 0.7::float8 ELSE 0.9::float8 END, 1::float8),
                 CASE WHEN sex = 'F' THEN -0.241::float8 ELSE -0.302::float8 END)
         * power(greatest(scr / CASE WHEN sex = 'F' THEN 0.7::float8 ELSE 0.9::float8 END, 1::float8),
                 -1.200::float8)
         * power(0.9938::float8, age_years::float8)
         * CASE WHEN sex = 'F' THEN 1.012::float8 ELSE 1::float8 END
$$;

-- The original version, kept only so step 60 can measure how much the literal types mattered.
CREATE OR REPLACE FUNCTION ref.egfr_ckd_epi_2021_numeric_literals(scr double precision, age_years integer, sex text)
RETURNS double precision LANGUAGE sql IMMUTABLE AS $$
  SELECT 142
         * power(least(scr / CASE WHEN sex = 'F' THEN 0.7 ELSE 0.9 END, 1),
                 CASE WHEN sex = 'F' THEN -0.241 ELSE -0.302 END)
         * power(greatest(scr / CASE WHEN sex = 'F' THEN 0.7 ELSE 0.9 END, 1), -1.200)
         * power(0.9938, age_years)
         * CASE WHEN sex = 'F' THEN 1.012 ELSE 1 END
$$;

CREATE OR REPLACE FUNCTION ref.hcc_from_egfr(egfr double precision)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN egfr IS NULL THEN NULL
              WHEN egfr >= 60 THEN NULL
              WHEN egfr >= 45 THEN 329
              WHEN egfr >= 30 THEN 328
              ELSE 327 END
$$;

DROP TABLE IF EXISTS study.rule_flag_sql CASCADE;

CREATE TABLE study.rule_flag_sql AS
WITH sp AS (
  SELECT ref.p('a1c_threshold')::float8  AS a1c_cut,
         ref.p('egfr_threshold')::float8 AS egfr_cut,
         ref.p('kdigo_min_days')::int    AS min_days,
         ref.p('uacr_threshold')::float8 AS uacr_cut
),
scen AS (SELECT DISTINCT scenario FROM study.lab_value),

-- ---------------------------------------------------------------- diabetes
dm AS (
  SELECT l.scenario, l.patient_id,
         count(*) AS n_abnormal,
         count(DISTINCT l.draw_date) AS n_abnormal_days
  FROM study.lab_value l, sp
  WHERE l.lab = 'a1c' AND l.value >= sp.a1c_cut
  GROUP BY l.scenario, l.patient_id
),
dm_flags AS (
  SELECT dm.scenario, dm.patient_id, 38 AS hcc,
         dm.n_abnormal >= 1 AS t1,
         dm.n_abnormal_days >= 2 AS t2,
         (dm.n_abnormal_days >= 2) OR (dm.n_abnormal >= 1 AND med.patient_id IS NOT NULL) AS t3
  FROM dm
  LEFT JOIN study.dm_med med USING (patient_id)
),

-- ---------------------------------------------------------------- kidney
cr AS (
  SELECT l.scenario, l.patient_id, l.draw_id, l.draw_ts, l.draw_date, l.setting,
         ref.egfr_ckd_epi_2021(l.value, date_part('year', age(l.draw_date, c.birth_date))::int, c.sex) AS egfr
  FROM study.lab_value l
  JOIN study.cohort c USING (patient_id)
  WHERE l.lab = 'creatinine'
),
t1 AS (
  SELECT scenario, patient_id, ref.hcc_from_egfr(min(egfr)) AS hcc
  FROM cr, sp WHERE egfr < sp.egfr_cut
  GROUP BY scenario, patient_id
),
t2 AS (
  SELECT scenario, patient_id,
         ref.hcc_from_egfr(percentile_cont(0.5) WITHIN GROUP (ORDER BY egfr)) AS hcc
  FROM cr, sp WHERE egfr < sp.egfr_cut
  GROUP BY scenario, patient_id, sp.min_days
  HAVING max(draw_date) - min(draw_date) >= sp.min_days
),
last_op AS (
  SELECT DISTINCT ON (scenario, patient_id) scenario, patient_id, egfr AS last_egfr
  FROM cr WHERE setting = 'outpatient'
  ORDER BY scenario, patient_id, draw_ts DESC, draw_id DESC
),
op_low AS (
  SELECT scenario, patient_id,
         max(draw_date) - min(draw_date) AS span,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY egfr) AS egfr_med
  FROM cr, sp WHERE setting = 'outpatient' AND egfr < sp.egfr_cut
  GROUP BY scenario, patient_id
),
alb AS (
  SELECT DISTINCT l.scenario, l.patient_id
  FROM study.lab_value l, sp
  WHERE l.lab = 'uacr' AND l.value >= sp.uacr_cut
),
t3 AS (
  SELECT o.scenario, o.patient_id, ref.hcc_from_egfr(o.egfr_med) AS hcc
  FROM op_low o
  JOIN last_op lo USING (scenario, patient_id)
  LEFT JOIN alb a USING (scenario, patient_id)
  CROSS JOIN sp
  WHERE (o.span >= sp.min_days OR a.patient_id IS NOT NULL)
    AND lo.last_egfr < sp.egfr_cut
),
ckd_long AS (
  SELECT scenario, patient_id, hcc, 't1' AS tier FROM t1
  UNION ALL SELECT scenario, patient_id, hcc, 't2' FROM t2
  UNION ALL SELECT scenario, patient_id, hcc, 't3' FROM t3
),
ckd_flags AS (
  SELECT scenario, patient_id, hcc,
         bool_or(tier = 't1') AS t1, bool_or(tier = 't2') AS t2, bool_or(tier = 't3') AS t3
  FROM ckd_long
  GROUP BY scenario, patient_id, hcc
),
all_flags AS (
  SELECT * FROM dm_flags WHERE t1 OR t2 OR t3
  UNION ALL
  SELECT * FROM ckd_flags
),
grid AS (
  SELECT s.scenario, c.patient_id, h.hcc
  FROM scen s
  CROSS JOIN study.cohort c
  CROSS JOIN (VALUES (38), (329), (328), (327)) AS h(hcc)
)
SELECT g.scenario, g.patient_id, g.hcc,
       coalesce(f.t1, false) AS t1,
       coalesce(f.t2, false) AS t2,
       coalesce(f.t3, false) AS t3
FROM grid g
LEFT JOIN all_flags f USING (scenario, patient_id, hcc);

CREATE INDEX ON study.rule_flag_sql (scenario, patient_id, hcc);
