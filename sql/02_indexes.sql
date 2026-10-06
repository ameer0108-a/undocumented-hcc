-- 02_indexes.sql
-- Built once after all batches are in. Building them during the load would slow every insert.

CREATE INDEX IF NOT EXISTS ix_enc_patient   ON ehr.encounter (patient_id, start_ts);
CREATE INDEX IF NOT EXISTS ix_cond_patient  ON ehr.condition (patient_id);
CREATE INDEX IF NOT EXISTS ix_cond_concept  ON ehr.condition (concept_id);
CREATE INDEX IF NOT EXISTS ix_obs_concept   ON ehr.observation (concept_id, patient_id, obs_ts);
CREATE INDEX IF NOT EXISTS ix_med_patient   ON ehr.medication (patient_id);
CREATE INDEX IF NOT EXISTS ix_med_concept   ON ehr.medication (concept_id);

ANALYZE;
