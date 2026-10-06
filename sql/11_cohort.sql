-- 11_cohort.sql
-- Medicare-age cohort as of the index date, plus a simple attrition table.

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION ref.p(k text) RETURNS text
LANGUAGE sql STABLE AS $$ SELECT value FROM ref.study_params WHERE key = k $$;

DROP TABLE IF EXISTS study.cohort, study.attrition CASCADE;

CREATE TABLE study.cohort AS
WITH params AS (
  SELECT ref.p('index_date')::date AS index_date,
         ref.p('window_start')::date AS window_start,
         ref.p('min_age')::int AS min_age
),
visits AS (
  -- A visit day is any day with an office-type encounter. ED and inpatient days are counted separately.
  SELECT e.patient_id,
         count(DISTINCT (e.start_ts AT TIME ZONE 'UTC')::date)
           FILTER (WHERE e.encounter_class IN ('wellness', 'ambulatory', 'outpatient')) AS office_days,
         count(DISTINCT (e.start_ts AT TIME ZONE 'UTC')::date)
           FILTER (WHERE e.encounter_class IN ('inpatient', 'emergency')) AS acute_days,
         count(*) AS encounters
  FROM ehr.encounter e, params p
  WHERE (e.start_ts AT TIME ZONE 'UTC')::date BETWEEN p.window_start AND p.index_date
  GROUP BY e.patient_id
)
SELECT pt.patient_id,
       pt.birth_date,
       pt.sex,
       pt.race,
       pt.ethnicity,
       pt.county,
       date_part('year', age(p.index_date, pt.birth_date))::int AS age,
       v.office_days,
       v.acute_days,
       v.encounters,
       round(v.office_days / 2.0, 1) AS visits_per_year,
       CASE WHEN v.office_days / 2.0 <= 2 THEN '2 or fewer'
            WHEN v.office_days / 2.0 < 6  THEN '3 to 5'
            ELSE '6 or more' END AS visit_band
FROM ehr.patient pt
CROSS JOIN params p
JOIN visits v ON v.patient_id = pt.patient_id
WHERE date_part('year', age(p.index_date, pt.birth_date)) >= p.min_age
  AND (pt.death_date IS NULL OR pt.death_date > p.index_date);

ALTER TABLE study.cohort ADD PRIMARY KEY (patient_id);

CREATE TABLE study.attrition AS
WITH p AS (SELECT ref.p('index_date')::date AS index_date, ref.p('window_start')::date AS window_start)
SELECT 1 AS step, 'Synthetic patients generated (alive, NC, ages 65-100 requested)' AS description,
       (SELECT count(*) FROM ehr.patient) AS n
UNION ALL
SELECT 2, 'Age 65 or older on the index date',
       (SELECT count(*) FROM ehr.patient pt, p WHERE date_part('year', age(p.index_date, pt.birth_date)) >= 65)
UNION ALL
SELECT 3, 'And at least one encounter in the two-year window',
       (SELECT count(*) FROM study.cohort);
