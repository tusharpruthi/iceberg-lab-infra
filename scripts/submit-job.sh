#!/usr/bin/env bash
# Submits one run of the Flink job to the EMR cluster via `aws emr add-steps`.
#
# Note: the RDS password is resolved locally (via `terraform output`) and embedded directly in
# the step's arguments — a deliberate playground simplification. It means the password is
# visible to anyone who can call `aws emr describe-step`/`list-steps` on this cluster, and in the
# step's logs. Accepted here since this stack only ever holds disposable test data; see
# PLAN.md and variables.tf's postgres_master_password for the fuller reasoning and how to
# reintroduce SSM-based fetching if that stops being true.
#
# Usage: scripts/submit-job.sh s3://<bucket>/path/to/flink-iceberg-playground-1.0-SNAPSHOT.jar
set -euo pipefail
cd "$(dirname "$0")/.."

JAR_S3_PATH="${1:?Usage: submit-job.sh s3://bucket/path/to/flink-iceberg-playground-1.0-SNAPSHOT.jar}"

CLUSTER_ID=$(terraform output -raw emr_cluster_id 2>/dev/null || true)
if [ -z "${CLUSTER_ID:-}" ] || [ "$CLUSTER_ID" = "null" ]; then
  echo "No EMR cluster is up — run scripts/start.sh first." >&2
  exit 1
fi

DB_PASSWORD=$(terraform output -raw postgres_master_password)
POSTGRES_HOST=$(terraform output -raw postgres_address)
POSTGRES_PORT=$(terraform output -raw postgres_port)
POSTGRES_DATABASE=$(terraform output -raw postgres_db_name)
POSTGRES_USERNAME=$(terraform output -raw postgres_username)
ICEBERG_WAREHOUSE=$(terraform output -raw warehouse_path)
ICEBERG_CATALOG_NAME=$(terraform output -raw glue_database_name)
REGION=$(terraform output -raw region)

# NOTE (verify before relying on this): EMR runs Flink on YARN, so job submission is `flink run
# -m yarn-cluster` (per-job YARN mode), not the standalone JobManager/TaskManager setup the local
# Docker stack uses. Confirm this invocation against the cluster's actual Flink version/mode —
# see the emr_release_label caveat in PLAN.md/README before the first real run.
ON_CLUSTER_SCRIPT=$(cat <<SCRIPT
set -euo pipefail
export POSTGRES_HOST='${POSTGRES_HOST}'
export POSTGRES_PORT='${POSTGRES_PORT}'
export POSTGRES_DATABASE='${POSTGRES_DATABASE}'
export POSTGRES_USERNAME='${POSTGRES_USERNAME}'
export POSTGRES_PASSWORD='${DB_PASSWORD}'
export POSTGRES_SLOT_NAME='iceberg_wal_sync_slot'
export POSTGRES_PUBLICATION_NAME='iceberg_wal_sync_pub'
export POSTGRES_TABLES='orders,customers'
export ICEBERG_CATALOG_NAME='${ICEBERG_CATALOG_NAME}'
export ICEBERG_WAREHOUSE='${ICEBERG_WAREHOUSE}'
export AWS_REGION='${REGION}'
aws s3 cp '${JAR_S3_PATH}' /tmp/flink-iceberg-playground.jar
flink run -m yarn-cluster -c com.hevo.icebergplayground.job.IcebergWalSyncJob /tmp/flink-iceberg-playground.jar prod
SCRIPT
)

STEP_JSON=$(python3 -c '
import json, sys
script = sys.argv[1]
print(json.dumps([{
    "Type": "CUSTOM_JAR",
    "Name": "iceberg-wal-sync",
    "ActionOnFailure": "CONTINUE",
    "Jar": "command-runner.jar",
    "Args": ["bash", "-c", script],
}]))
' "$ON_CLUSTER_SCRIPT")

STEP_ID=$(aws emr add-steps --cluster-id "$CLUSTER_ID" --steps "$STEP_JSON" --query 'StepIds[0]' --output text)
echo "Step ${STEP_ID} submitted to cluster ${CLUSTER_ID}."
echo "Watch it with:"
echo "  aws emr describe-step --cluster-id ${CLUSTER_ID} --step-id ${STEP_ID}"
