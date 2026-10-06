-- 01_normalize_batch.sql
-- Moves one Synthea batch from stg.* into the normalized ehr.* tables.
-- Called by scripts/load_batch.sh after the CSVs are copied into stg.
-- Expects psql variables :batch and :seed.

\set ON_ERROR_STOP on
BEGIN;

-- 1. Concept dictionary. Every code that shows up in this batch gets an id.
INSERT INTO ehr.concept (vocabulary, code, description)
SELECT DISTINCT ON (vocabulary, code) vocabulary, code, description
FROM (
  SELECT 'SNOMED' AS vocabulary, code, description FROM stg.conditions
  UNION ALL SELECT 'SNOMED', code, description FROM stg.encounters
  UNION ALL SELECT 'SNOMED', reasoncode, reasondescription FROM stg.encounters WHERE reasoncode <> ''
  UNION ALL SELECT 'LOINC', code, description FROM stg.observations
  UNION ALL SELECT 'RXNORM', code, description FROM stg.medications
  UNION ALL SELECT 'SNOMED', reasoncode, reasondescription FROM stg.medications WHERE reasoncode <> ''
  UNION ALL SELECT 'SNOMED', code, description FROM stg.procedures
  UNION ALL SELECT 'SNOMED', reasoncode, reasondescription FROM stg.procedures WHERE reasoncode <> ''
  UNION ALL SELECT 'CVX', code, description FROM stg.immunizations
  UNION ALL SELECT 'SNOMED', code, description FROM stg.careplans
  UNION ALL SELECT 'SNOMED', reasoncode, reasondescription FROM stg.careplans WHERE reasoncode <> ''
  UNION ALL SELECT 'SNOMED', code, description FROM stg.allergies
  UNION ALL SELECT 'SNOMED', code, description FROM stg.devices
  UNION ALL SELECT 'SNOMED', code, description FROM stg.supplies
) s
WHERE code IS NOT NULL AND code <> ''
ORDER BY vocabulary, code, description
ON CONFLICT (vocabulary, code) DO NOTHING;

-- 2. Shared dimension tables (same NC organizations show up in every batch).
INSERT INTO ehr.organization SELECT id::uuid, name, city, zip FROM stg.organizations
ON CONFLICT DO NOTHING;
INSERT INTO ehr.provider SELECT id::uuid, organization::uuid, speciality FROM stg.providers
ON CONFLICT DO NOTHING;
INSERT INTO ehr.payer SELECT id::uuid, name, ownership FROM stg.payers
ON CONFLICT DO NOTHING;

-- 3. Patients. Names, SSNs and addresses are left behind on purpose.
INSERT INTO ehr.patient (person_uuid, batch, birth_date, death_date, sex, race, ethnicity,
                         county, fips, zip, income)
SELECT id::uuid, :batch, birthdate::date, NULLIF(deathdate, '')::date, gender, race, ethnicity,
       county, NULLIF(fips, ''), NULLIF(zip, ''), NULLIF(income, '')::numeric::integer
FROM stg.patients;

CREATE TEMP TABLE pmap ON COMMIT DROP AS
SELECT person_uuid::text AS person_uuid, patient_id FROM ehr.patient WHERE batch = :batch;
CREATE INDEX ON pmap (person_uuid);
ANALYZE pmap;

-- 4. Encounters.
INSERT INTO ehr.encounter (encounter_uuid, patient_id, batch, start_ts, stop_ts, encounter_class,
                           concept_id, reason_concept_id, payer_uuid, provider_uuid)
SELECT e.id::uuid, p.patient_id, :batch, e.start::timestamptz, NULLIF(e.stop, '')::timestamptz,
       e.encounterclass, c.concept_id, rc.concept_id, NULLIF(e.payer, '')::uuid,
       NULLIF(e.provider, '')::uuid
FROM stg.encounters e
JOIN pmap p ON p.person_uuid = e.patient
LEFT JOIN ehr.concept c  ON c.vocabulary = 'SNOMED' AND c.code = e.code
LEFT JOIN ehr.concept rc ON rc.vocabulary = 'SNOMED' AND rc.code = NULLIF(e.reasoncode, '');

CREATE TEMP TABLE emap ON COMMIT DROP AS
SELECT encounter_uuid::text AS encounter_uuid, encounter_id FROM ehr.encounter WHERE batch = :batch;
CREATE INDEX ON emap (encounter_uuid);
ANALYZE emap;

-- 5. Clinical tables.
INSERT INTO ehr.condition (patient_id, encounter_id, start_date, stop_date, concept_id)
SELECT p.patient_id, e.encounter_id, s.start::date, NULLIF(s.stop, '')::date, c.concept_id
FROM stg.conditions s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'SNOMED' AND c.code = s.code;

INSERT INTO ehr.observation (patient_id, encounter_id, obs_ts, category, concept_id,
                             value_num, value_text, units)
SELECT p.patient_id, e.encounter_id, s.date::timestamptz, NULLIF(s.category, ''), c.concept_id,
       CASE WHEN s.type = 'numeric' AND s.value ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
            THEN s.value::double precision END,
       CASE WHEN s.type = 'numeric' AND s.value ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
            THEN NULL ELSE s.value END,
       NULLIF(s.units, '')
FROM stg.observations s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'LOINC' AND c.code = s.code;

INSERT INTO ehr.medication (patient_id, encounter_id, start_ts, stop_ts, concept_id,
                            reason_concept_id, dispenses)
SELECT p.patient_id, e.encounter_id, s.start::timestamptz, NULLIF(s.stop, '')::timestamptz,
       c.concept_id, rc.concept_id, NULLIF(s.dispenses, '')::integer
FROM stg.medications s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'RXNORM' AND c.code = s.code
LEFT JOIN ehr.concept rc ON rc.vocabulary = 'SNOMED' AND rc.code = NULLIF(s.reasoncode, '');

INSERT INTO ehr.procedure (patient_id, encounter_id, start_ts, concept_id, reason_concept_id)
SELECT p.patient_id, e.encounter_id, s.start::timestamptz, c.concept_id, rc.concept_id
FROM stg.procedures s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'SNOMED' AND c.code = s.code
LEFT JOIN ehr.concept rc ON rc.vocabulary = 'SNOMED' AND rc.code = NULLIF(s.reasoncode, '');

INSERT INTO ehr.immunization (patient_id, encounter_id, imm_ts, concept_id)
SELECT p.patient_id, e.encounter_id, s.date::timestamptz, c.concept_id
FROM stg.immunizations s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'CVX' AND c.code = s.code;

INSERT INTO ehr.careplan (patient_id, encounter_id, start_date, stop_date, concept_id, reason_concept_id)
SELECT p.patient_id, e.encounter_id, s.start::date, NULLIF(s.stop, '')::date, c.concept_id, rc.concept_id
FROM stg.careplans s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'SNOMED' AND c.code = s.code
LEFT JOIN ehr.concept rc ON rc.vocabulary = 'SNOMED' AND rc.code = NULLIF(s.reasoncode, '');

INSERT INTO ehr.allergy (patient_id, encounter_id, start_date, stop_date, concept_id, allergy_type, category)
SELECT p.patient_id, e.encounter_id, s.start::date, NULLIF(s.stop, '')::date, c.concept_id, s.type, s.category
FROM stg.allergies s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'SNOMED' AND c.code = s.code;

INSERT INTO ehr.device (patient_id, encounter_id, start_ts, stop_ts, concept_id)
SELECT p.patient_id, e.encounter_id, s.start::timestamptz, NULLIF(s.stop, '')::timestamptz, c.concept_id
FROM stg.devices s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'SNOMED' AND c.code = s.code;

INSERT INTO ehr.supply (patient_id, encounter_id, supply_date, concept_id, quantity)
SELECT p.patient_id, e.encounter_id, s.date::date, c.concept_id, NULLIF(s.quantity, '')::integer
FROM stg.supplies s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter
JOIN ehr.concept c ON c.vocabulary = 'SNOMED' AND c.code = s.code;

INSERT INTO ehr.imaging_study (patient_id, encounter_id, study_ts, modality, bodysite, procedure_code)
SELECT p.patient_id, e.encounter_id, s.date::timestamptz, s.modality_code, s.bodysite_description,
       s.procedure_code
FROM stg.imaging_studies s
JOIN pmap p ON p.person_uuid = s.patient
LEFT JOIN emap e ON e.encounter_uuid = s.encounter;

-- 6. Log the batch so reruns can skip it.
INSERT INTO ehr.load_log (batch, seed, n_patients, n_rows)
SELECT :batch, :seed,
  (SELECT count(*) FROM stg.patients),
  (SELECT count(*) FROM stg.patients) + (SELECT count(*) FROM stg.encounters)
  + (SELECT count(*) FROM stg.conditions) + (SELECT count(*) FROM stg.observations)
  + (SELECT count(*) FROM stg.medications) + (SELECT count(*) FROM stg.procedures)
  + (SELECT count(*) FROM stg.immunizations) + (SELECT count(*) FROM stg.careplans)
  + (SELECT count(*) FROM stg.allergies) + (SELECT count(*) FROM stg.devices)
  + (SELECT count(*) FROM stg.supplies) + (SELECT count(*) FROM stg.imaging_studies);

COMMIT;

TRUNCATE stg.patients, stg.encounters, stg.conditions, stg.observations, stg.medications,
  stg.procedures, stg.immunizations, stg.careplans, stg.allergies, stg.devices, stg.supplies,
  stg.imaging_studies, stg.organizations, stg.providers, stg.payers;
