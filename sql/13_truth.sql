-- 13_truth.sql
-- Ground truth for each cohort patient, taken from Synthea's own condition records
-- before any masking. In Synthea every true condition is also coded, so this is
-- both "what the patient has" and "what the chart said before we hid it".
--
-- Diabetes truth is the type 2 diabetes diagnosis itself (SNOMED 44054006), not "any code
-- in HCC 36-38". Synthea's kidney module labels nephropathy, microalbuminuria and proteinuria
-- as "due to diabetes" even in patients whose kidney disease came from hypertension and who
-- never have diabetes. Those codes map to HCC 37, so counting them as diabetes would call
-- thousands of non-diabetic people diabetic. They are flagged as dm_code_artifact instead.

SET client_min_messages = warning;

DROP TABLE IF EXISTS study.truth CASCADE;

CREATE TABLE study.truth AS
WITH p AS (
  SELECT ref.p('index_date')::date AS index_date,
         ref.p('measurement_year_start')::date AS my_start
),
active AS (
  -- active at any point during the measurement year
  SELECT m.*
  FROM study.condition_mapped m, p
  WHERE m.start_date <= p.index_date
    AND (m.stop_date IS NULL OR m.stop_date >= p.my_start)
),
per_patient AS (
  SELECT patient_id,
         bool_or(snomed_code = '44054006')        AS dm_true,
         bool_or(hcc IN (36, 37, 38))             AS dm_family_coded,
         -- V28 hierarchy inside the diabetes family: 36 beats 37 beats 38
         min(hcc) FILTER (WHERE hcc IN (36, 37, 38)) AS dm_family_hcc,
         bool_or(snomed_code = '714628002')       AS prediabetes,
         bool_or(snomed_code IN ('59621000', '38341003')) AS hypertension,
         max(CASE snomed_code WHEN '431855005' THEN 1 WHEN '431856006' THEN 2
                              WHEN '433144002' THEN 3 WHEN '431857002' THEN 4
                              WHEN '46177005'  THEN 5 END) AS ckd_stage_coded,
         -- V28 hierarchy inside the kidney family: 326 beats 327 beats 328 beats 329
         min(hcc) FILTER (WHERE hcc IN (326, 327, 328, 329)) AS ckd_hcc
  FROM active
  GROUP BY patient_id
)
SELECT c.patient_id,
       coalesce(pp.dm_true, false) AS dm_true,
       CASE WHEN pp.dm_true THEN pp.dm_family_hcc END AS dm_hcc,
       coalesce(pp.dm_family_coded, false) AND NOT coalesce(pp.dm_true, false) AS dm_code_artifact,
       coalesce(pp.prediabetes, false) AND NOT coalesce(pp.dm_true, false) AS prediabetes,
       coalesce(pp.hypertension, false) AS hypertension,
       coalesce(pp.ckd_stage_coded, 0) AS ckd_stage_coded,
       pp.ckd_hcc
FROM study.cohort c
LEFT JOIN per_patient pp USING (patient_id);

ALTER TABLE study.truth ADD PRIMARY KEY (patient_id);
