-- 14_lab_draws.sql
-- One row per lab draw in the lookback window: who, which lab, when, where, and what Synthea reported.
-- The R lab model keeps the timing and setting of these draws and replaces the values.

SET client_min_messages = warning;

DROP TABLE IF EXISTS study.lab_draw, study.dm_med CASCADE;

CREATE TABLE study.lab_draw AS
WITH p AS (SELECT ref.p('window_start')::date AS ws, ref.p('index_date')::date AS idx),
raw AS (
  SELECT o.patient_id, o.encounter_id, l.lab, o.obs_ts, o.value_num,
         -- when serum and whole-blood creatinine come back on the same encounter, keep the serum one
         row_number() OVER (PARTITION BY o.patient_id, o.encounter_id, l.lab
                            ORDER BY (k.code = '2160-0') DESC, o.obs_ts) AS rn
  FROM ehr.observation o
  JOIN ehr.concept k USING (concept_id)
  JOIN ref.lab_loinc l ON l.loinc = k.code
  JOIN study.cohort c ON c.patient_id = o.patient_id
  CROSS JOIN p
  WHERE (o.obs_ts AT TIME ZONE 'UTC')::date BETWEEN p.ws AND p.idx
    AND o.value_num IS NOT NULL
)
SELECT row_number() OVER (ORDER BY r.patient_id, r.lab, r.obs_ts, r.encounter_id) AS draw_id,
       r.patient_id, r.lab, r.encounter_id,
       r.obs_ts AS draw_ts,
       (r.obs_ts AT TIME ZONE 'UTC')::date AS draw_date,
       CASE WHEN e.encounter_class IN ('inpatient', 'emergency') THEN 'acute' ELSE 'outpatient' END AS setting,
       e.encounter_class,
       r.value_num AS synthea_value
FROM raw r
LEFT JOIN ehr.encounter e ON e.encounter_id = r.encounter_id
WHERE r.rn = 1;

ALTER TABLE study.lab_draw ADD PRIMARY KEY (draw_id);
CREATE INDEX ON study.lab_draw (patient_id, lab);

-- Patients with a glucose-lowering drug active at any point in the window.
-- Only the drug itself is used, never the reason code, because the reason code is a diagnosis.
CREATE TABLE study.dm_med AS
WITH p AS (SELECT ref.p('window_start')::date AS ws, ref.p('index_date')::date AS idx)
SELECT m.patient_id,
       string_agg(DISTINCT d.drug_class, ', ' ORDER BY d.drug_class) AS drug_classes
FROM ehr.medication m
JOIN ehr.concept k USING (concept_id)
JOIN ref.dm_medication d ON lower(k.description) LIKE d.ingredient_pattern
JOIN study.cohort c ON c.patient_id = m.patient_id
CROSS JOIN p
WHERE (m.start_ts AT TIME ZONE 'UTC')::date <= p.idx
  AND (m.stop_ts IS NULL OR (m.stop_ts AT TIME ZONE 'UTC')::date >= p.ws)
GROUP BY m.patient_id;

ALTER TABLE study.dm_med ADD PRIMARY KEY (patient_id);

-- Same thing, minus prescriptions Synthea writes with prediabetes as the reason.
-- Synthea puts about a quarter of its prediabetic patients on insulin, which real practice
-- does not do. The main analysis keeps them (decided before results); this table feeds
-- a sensitivity analysis that removes them.
DROP TABLE IF EXISTS study.dm_med_clean CASCADE;
CREATE TABLE study.dm_med_clean AS
WITH p AS (SELECT ref.p('window_start')::date AS ws, ref.p('index_date')::date AS idx)
SELECT m.patient_id,
       string_agg(DISTINCT d.drug_class, ', ' ORDER BY d.drug_class) AS drug_classes
FROM ehr.medication m
JOIN ehr.concept k USING (concept_id)
JOIN ref.dm_medication d ON lower(k.description) LIKE d.ingredient_pattern
JOIN study.cohort c ON c.patient_id = m.patient_id
LEFT JOIN ehr.concept rk ON rk.concept_id = m.reason_concept_id
CROSS JOIN p
WHERE (m.start_ts AT TIME ZONE 'UTC')::date <= p.idx
  AND (m.stop_ts IS NULL OR (m.stop_ts AT TIME ZONE 'UTC')::date >= p.ws)
  AND coalesce(rk.code, '') <> '714628002'
GROUP BY m.patient_id;

ALTER TABLE study.dm_med_clean ADD PRIMARY KEY (patient_id);
