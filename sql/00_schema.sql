SET client_min_messages = warning;
-- 00_schema.sql
-- Creates the four schemas and the normalized EHR tables.
--
--   stg    raw Synthea CSVs, all text, truncated after each batch
--   ehr    normalized synthetic EHR (integer keys, one concept dictionary)
--   ref    crosswalks and CMS reference tables
--   study  cohort, truth, masking, lab features, alerts, results
--
-- Synthea CSVs repeat UUIDs and long description strings on every row.
-- Swapping those for integer keys and a single concept table keeps the
-- full database small enough to sit on a laptop.

CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS ehr;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS study;

-- ---------------------------------------------------------------- staging
DROP TABLE IF EXISTS stg.patients, stg.encounters, stg.conditions, stg.observations,
  stg.medications, stg.procedures, stg.immunizations, stg.careplans, stg.allergies,
  stg.devices, stg.supplies, stg.imaging_studies, stg.organizations, stg.providers,
  stg.payers;

CREATE UNLOGGED TABLE stg.patients (id text, birthdate text, deathdate text, ssn text, drivers text,
  passport text, prefix text, first text, middle text, last text, suffix text, maiden text,
  marital text, race text, ethnicity text, gender text, birthplace text, address text, city text,
  state text, county text, fips text, zip text, lat text, lon text, healthcare_expenses text,
  healthcare_coverage text, income text);
CREATE UNLOGGED TABLE stg.encounters (id text, start text, stop text, patient text, organization text,
  provider text, payer text, encounterclass text, code text, description text,
  base_encounter_cost text, total_claim_cost text, payer_coverage text, reasoncode text,
  reasondescription text);
CREATE UNLOGGED TABLE stg.conditions (start text, stop text, patient text, encounter text, system text,
  code text, description text);
CREATE UNLOGGED TABLE stg.observations (date text, patient text, encounter text, category text,
  code text, description text, value text, units text, type text);
CREATE UNLOGGED TABLE stg.medications (start text, stop text, patient text, payer text, encounter text,
  code text, description text, base_cost text, payer_coverage text, dispenses text, totalcost text,
  reasoncode text, reasondescription text);
CREATE UNLOGGED TABLE stg.procedures (start text, stop text, patient text, encounter text, system text,
  code text, description text, base_cost text, reasoncode text, reasondescription text);
CREATE UNLOGGED TABLE stg.immunizations (date text, patient text, encounter text, code text,
  description text, base_cost text);
CREATE UNLOGGED TABLE stg.careplans (id text, start text, stop text, patient text, encounter text,
  code text, description text, reasoncode text, reasondescription text);
CREATE UNLOGGED TABLE stg.allergies (start text, stop text, patient text, encounter text, code text,
  system text, description text, type text, category text, reaction1 text, description1 text,
  severity1 text, reaction2 text, description2 text, severity2 text);
CREATE UNLOGGED TABLE stg.devices (start text, stop text, patient text, encounter text, code text,
  description text, udi text);
CREATE UNLOGGED TABLE stg.supplies (date text, patient text, encounter text, code text,
  description text, quantity text);
CREATE UNLOGGED TABLE stg.imaging_studies (id text, date text, patient text, encounter text,
  series_uid text, bodysite_code text, bodysite_description text, modality_code text,
  modality_description text, instance_uid text, sop_code text, sop_description text,
  procedure_code text);
CREATE UNLOGGED TABLE stg.organizations (id text, name text, address text, city text, state text,
  zip text, lat text, lon text, phone text, revenue text, utilization text, npi text);
CREATE UNLOGGED TABLE stg.providers (id text, organization text, name text, gender text,
  speciality text, address text, city text, state text, zip text, lat text, lon text,
  encounters text, procedures text, npi text);
CREATE UNLOGGED TABLE stg.payers (id text, name text, ownership text, address text, city text,
  state_headquartered text, zip text, phone text, amount_covered text, amount_uncovered text,
  revenue text, covered_encounters text, uncovered_encounters text, covered_medications text,
  uncovered_medications text, covered_procedures text, uncovered_procedures text,
  covered_immunizations text, uncovered_immunizations text, unique_customers text,
  qols_avg text, member_months text);

-- ---------------------------------------------------------------- ehr
DROP TABLE IF EXISTS ehr.observation, ehr.condition, ehr.medication, ehr.procedure,
  ehr.immunization, ehr.careplan, ehr.allergy, ehr.device, ehr.supply, ehr.imaging_study,
  ehr.encounter, ehr.patient, ehr.concept, ehr.organization, ehr.provider, ehr.payer,
  ehr.load_log CASCADE;

CREATE TABLE ehr.concept (
  concept_id   serial PRIMARY KEY,
  vocabulary   text NOT NULL,          -- SNOMED, LOINC, RXNORM, CVX, DICOM
  code         text NOT NULL,
  description  text,
  UNIQUE (vocabulary, code)
);

CREATE TABLE ehr.organization (org_uuid uuid PRIMARY KEY, name text, city text, zip text);
CREATE TABLE ehr.provider (provider_uuid uuid PRIMARY KEY, org_uuid uuid, specialty text);
CREATE TABLE ehr.payer (payer_uuid uuid PRIMARY KEY, name text, ownership text);

CREATE TABLE ehr.patient (
  patient_id   serial PRIMARY KEY,
  person_uuid  uuid UNIQUE NOT NULL,
  batch        smallint NOT NULL,
  birth_date   date NOT NULL,
  death_date   date,
  sex          char(1),
  race         text,
  ethnicity    text,
  county       text,
  fips         text,
  zip          text,
  income       integer
);

CREATE TABLE ehr.encounter (
  encounter_id    bigserial PRIMARY KEY,
  encounter_uuid  uuid UNIQUE NOT NULL,
  patient_id      integer NOT NULL REFERENCES ehr.patient,
  batch           smallint NOT NULL,
  start_ts        timestamptz NOT NULL,
  stop_ts         timestamptz,
  encounter_class text,
  concept_id      integer REFERENCES ehr.concept,
  reason_concept_id integer REFERENCES ehr.concept,
  payer_uuid      uuid,
  provider_uuid   uuid
);

CREATE TABLE ehr.condition (
  patient_id   integer NOT NULL,
  encounter_id bigint,
  start_date   date NOT NULL,
  stop_date    date,
  concept_id   integer NOT NULL
);

CREATE TABLE ehr.observation (
  patient_id   integer NOT NULL,
  encounter_id bigint,
  obs_ts       timestamptz NOT NULL,
  category     text,
  concept_id   integer NOT NULL,
  value_num    double precision,
  value_text   text,
  units        text
);

CREATE TABLE ehr.medication (
  patient_id   integer NOT NULL,
  encounter_id bigint,
  start_ts     timestamptz NOT NULL,
  stop_ts      timestamptz,
  concept_id   integer NOT NULL,
  reason_concept_id integer,
  dispenses    integer
);

CREATE TABLE ehr.procedure (
  patient_id   integer NOT NULL,
  encounter_id bigint,
  start_ts     timestamptz NOT NULL,
  concept_id   integer NOT NULL,
  reason_concept_id integer
);

CREATE TABLE ehr.immunization (patient_id integer NOT NULL, encounter_id bigint,
  imm_ts timestamptz NOT NULL, concept_id integer NOT NULL);
CREATE TABLE ehr.careplan (patient_id integer NOT NULL, encounter_id bigint, start_date date,
  stop_date date, concept_id integer NOT NULL, reason_concept_id integer);
CREATE TABLE ehr.allergy (patient_id integer NOT NULL, encounter_id bigint, start_date date,
  stop_date date, concept_id integer NOT NULL, allergy_type text, category text);
CREATE TABLE ehr.device (patient_id integer NOT NULL, encounter_id bigint, start_ts timestamptz,
  stop_ts timestamptz, concept_id integer NOT NULL);
CREATE TABLE ehr.supply (patient_id integer NOT NULL, encounter_id bigint, supply_date date,
  concept_id integer NOT NULL, quantity integer);
CREATE TABLE ehr.imaging_study (patient_id integer NOT NULL, encounter_id bigint,
  study_ts timestamptz, modality text, bodysite text, procedure_code text);

CREATE TABLE ehr.load_log (
  batch        smallint PRIMARY KEY,
  seed         bigint,
  loaded_at    timestamptz DEFAULT now(),
  n_patients   integer,
  n_rows       bigint
);
