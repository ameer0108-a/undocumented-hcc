-- 12_crosswalk.sql
-- SNOMED CT (what Synthea records) -> ICD-10-CM (what gets billed) -> CMS-HCC V28 (what gets paid).
-- Also measures how much of the chronic condition burden the crosswalk actually covers.

SET client_min_messages = warning;

DROP TABLE IF EXISTS study.chronic_concept, study.condition_mapped, study.crosswalk_coverage CASCADE;

-- "Chronic" is defined from the data, not from a hand-picked list:
-- a disorder concept is chronic if at least half of its records never get a stop date.
CREATE TABLE study.chronic_concept AS
SELECT c.concept_id, k.code AS snomed_code, k.description,
       count(*) AS n_records,
       avg((c.stop_date IS NULL)::int)::numeric(4,3) AS share_open
FROM ehr.condition c
JOIN ehr.concept k USING (concept_id)
JOIN study.cohort USING (patient_id)
WHERE k.description LIKE '%(disorder)'
GROUP BY c.concept_id, k.code, k.description
HAVING avg((c.stop_date IS NULL)::int) >= 0.5;

-- Every cohort condition record with its ICD-10-CM code and V28 HCC (null when unmapped).
CREATE TABLE study.condition_mapped AS
SELECT c.patient_id, c.start_date, c.stop_date, k.code AS snomed_code, k.description,
       x.icd10cm, h.hcc,
       (cc.concept_id IS NOT NULL) AS is_chronic
FROM ehr.condition c
JOIN study.cohort USING (patient_id)
JOIN ehr.concept k USING (concept_id)
LEFT JOIN study.chronic_concept cc USING (concept_id)
LEFT JOIN ref.snomed_icd10cm x ON x.snomed_code = k.code
LEFT JOIN ref.v28_dx_to_hcc h ON h.icd10cm_nodot = replace(x.icd10cm, '.', '');

CREATE INDEX ON study.condition_mapped (patient_id);

CREATE TABLE study.crosswalk_coverage AS
SELECT 'chronic disorder records' AS scope,
       count(*) AS n_records,
       count(*) FILTER (WHERE icd10cm IS NOT NULL) AS n_mapped_icd10,
       round(100.0 * count(*) FILTER (WHERE icd10cm IS NOT NULL) / count(*), 2) AS pct_mapped_icd10,
       count(*) FILTER (WHERE hcc IS NOT NULL) AS n_mapped_hcc,
       round(100.0 * count(*) FILTER (WHERE hcc IS NOT NULL) / count(*), 2) AS pct_mapped_hcc,
       count(DISTINCT snomed_code) AS n_concepts,
       count(DISTINCT snomed_code) FILTER (WHERE icd10cm IS NULL) AS n_concepts_unmapped
FROM (SELECT DISTINCT ON (patient_id, snomed_code, start_date) * FROM study.condition_mapped
      WHERE is_chronic) x
UNION ALL
SELECT 'all disorder records',
       count(*), count(*) FILTER (WHERE icd10cm IS NOT NULL),
       round(100.0 * count(*) FILTER (WHERE icd10cm IS NOT NULL) / count(*), 2),
       count(*) FILTER (WHERE hcc IS NOT NULL),
       round(100.0 * count(*) FILTER (WHERE hcc IS NOT NULL) / count(*), 2),
       count(DISTINCT snomed_code), count(DISTINCT snomed_code) FILTER (WHERE icd10cm IS NULL)
FROM (SELECT DISTINCT ON (patient_id, snomed_code, start_date) * FROM study.condition_mapped
      WHERE description LIKE '%(disorder)') x;
