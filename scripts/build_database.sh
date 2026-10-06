#!/usr/bin/env bash
# Generates the synthetic population in batches and loads each batch into PostgreSQL.
#
# Usage:
#   scripts/build_database.sh                 # 20 batches of 1,000 (the setup used in the write-up)
#   N_BATCHES=2 scripts/build_database.sh     # quick test run
#
# Needs: Java 17+, psql, and synthea-with-dependencies.jar in ./synthea/
# Connection uses the normal PG* environment variables (PGHOST, PGUSER, PGDATABASE, PGPASSWORD).
#
# Each batch is generated, copied into the stg schema, normalized into ehr, and then
# its CSV folder is deleted. That keeps peak disk use around 1 GB instead of 15+ GB.

set -euo pipefail
cd "$(dirname "$0")/.."

N_BATCHES=${N_BATCHES:-20}
BATCH_SIZE=${BATCH_SIZE:-1000}
BASE_SEED=${BASE_SEED:-20250000}
AGE_RANGE=${AGE_RANGE:-65-100}
END_DATE=${END_DATE:-20260101}
STATE=${STATE:-"North Carolina"}
JAR=${JAR:-synthea/synthea-with-dependencies.jar}
WORK=${WORK:-synthea/batches}
KEEP_CSV=${KEEP_CSV:-0}
JAVA_MEM=${JAVA_MEM:-4g}   # 5g was OOM-killed once on a 7 GB machine also running PostgreSQL

export PGHOST=${PGHOST:-localhost} PGUSER=${PGUSER:-ehr} PGDATABASE=${PGDATABASE:-ehr}
mkdir -p "$WORK" output/logs

# Schema only gets created once. Rerunning skips batches already in ehr.load_log.
if ! psql -tAc "select to_regclass('ehr.load_log')" | grep -q load_log; then
  psql -q -v ON_ERROR_STOP=1 -f sql/00_schema.sql
fi

TABLES="patients encounters conditions observations medications procedures immunizations
careplans allergies devices supplies imaging_studies organizations providers payers"

for b in $(seq 1 "$N_BATCHES"); do
  if [ "$(psql -tAc "select count(*) from ehr.load_log where batch = $b")" = "1" ]; then
    echo "batch $b already loaded, skipping"
    continue
  fi
  seed=$((BASE_SEED + b))
  out="$WORK/b$(printf %02d "$b")"
  echo "$(date '+%H:%M:%S') batch $b: generating $BATCH_SIZE patients aged $AGE_RANGE (seed $seed)"
  rm -rf "$out"
  java -Xmx"$JAVA_MEM" -jar "$JAR" -c config/synthea.properties \
    -s "$seed" -cs "$seed" -p "$BATCH_SIZE" -a "$AGE_RANGE" -e "$END_DATE" \
    --exporter.baseDirectory="$out/" "$STATE" > "output/logs/synthea_b$b.log" 2>&1

  echo "$(date '+%H:%M:%S') batch $b: loading"
  for t in $TABLES; do
    f="$out/csv/$t.csv"
    [ -f "$f" ] || continue
    psql -q -v ON_ERROR_STOP=1 -c "\\copy stg.$t FROM '$f' WITH (FORMAT csv, HEADER true)"
  done
  psql -q -v ON_ERROR_STOP=1 -v batch="$b" -v seed="$seed" -f sql/01_normalize_batch.sql
  [ "$KEEP_CSV" = "1" ] || rm -rf "$out"
  echo "$(date '+%H:%M:%S') batch $b: done"
done

echo "Building indexes"
psql -q -v ON_ERROR_STOP=1 -f sql/02_indexes.sql
psql -c "select count(*) as batches, sum(n_patients) as patients, sum(n_rows) as rows from ehr.load_log"
