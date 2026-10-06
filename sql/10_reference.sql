-- 10_reference.sql
-- Reference tables. scripts/run_pipeline.sh fills them from reference/*.csv and config/*.csv.

SET client_min_messages = warning;

DROP TABLE IF EXISTS ref.study_params, ref.lab_model_params, ref.snomed_icd10cm,
  ref.v28_dx_to_hcc, ref.v28_labels, ref.v28_hierarchy, ref.v28_coefficient,
  ref.lab_loinc, ref.dm_medication CASCADE;

CREATE TABLE ref.study_params     (key text PRIMARY KEY, value text NOT NULL, source_or_reason text);
CREATE TABLE ref.lab_model_params (key text PRIMARY KEY, value text NOT NULL, source_or_reason text);

CREATE TABLE ref.snomed_icd10cm (
  snomed_code        text PRIMARY KEY,
  snomed_description text,
  icd10cm            text NOT NULL,      -- with the dot, as people write it
  map_note           text
);

CREATE TABLE ref.v28_dx_to_hcc   (icd10cm_nodot text, hcc integer, PRIMARY KEY (icd10cm_nodot, hcc));
CREATE TABLE ref.v28_labels      (hcc integer PRIMARY KEY, label text);
CREATE TABLE ref.v28_hierarchy   (hcc_parent integer, hcc_child integer, PRIMARY KEY (hcc_parent, hcc_child));
CREATE TABLE ref.v28_coefficient (hcc integer PRIMARY KEY, coefficient numeric NOT NULL);

-- Which LOINC codes count as which lab. Both creatinine codes are the same test for our purposes.
CREATE TABLE ref.lab_loinc (loinc text PRIMARY KEY, lab text NOT NULL, note text);
INSERT INTO ref.lab_loinc VALUES
  ('4548-4',  'a1c',        'Hemoglobin A1c/Hemoglobin.total in Blood'),
  ('2160-0',  'creatinine', 'Creatinine [Mass/volume] in Serum or Plasma'),
  ('38483-4', 'creatinine', 'Creatinine [Mass/volume] in Blood'),
  ('14959-1', 'uacr',       'Microalbumin/Creatinine [Mass Ratio] in Urine');

-- Glucose-lowering drugs. Matched on ingredient text so new Synthea versions still match.
CREATE TABLE ref.dm_medication (ingredient_pattern text PRIMARY KEY, drug_class text);
INSERT INTO ref.dm_medication VALUES
  ('%metformin%',     'biguanide'),
  ('%insulin%',       'insulin'),
  ('%glipizide%',     'sulfonylurea'),
  ('%glyburide%',     'sulfonylurea'),
  ('%glimepiride%',   'sulfonylurea'),
  ('%liraglutide%',   'GLP-1 RA'),
  ('%semaglutide%',   'GLP-1 RA'),
  ('%dulaglutide%',   'GLP-1 RA'),
  ('%canagliflozin%', 'SGLT2i'),
  ('%empagliflozin%', 'SGLT2i'),
  ('%dapagliflozin%', 'SGLT2i'),
  ('%sitagliptin%',   'DPP-4i'),
  ('%linagliptin%',   'DPP-4i'),
  ('%pioglitazone%',  'TZD');
