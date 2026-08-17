#!/usr/bin/env bash
# Terminates the EMR cluster (holds no state that matters — Iceberg data lives in S3/Glue) and
# pauses RDS (kept, not destroyed — it holds the actual source tables). Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the security group's allowed_cidrs current here too — otherwise this apply would silently
# revert it to whatever's in terraform.tfvars, dropping both your live IP and any static entries
# that aren't in tfvars (see scripts/start.sh for the full reasoning).
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
if [ -z "$MY_IP" ]; then
  echo "Couldn't determine your current public IP — check your network, or set allowed_cidrs manually." >&2
  exit 1
fi

STATIC_CIDRS_JSON=$(terraform output -json static_allowed_cidrs 2>/dev/null || echo "[]")
ALLOWED_CIDRS_JSON=$(python3 -c "
import json, sys
static = json.loads(sys.argv[1])
my_ip_cidr = sys.argv[2]
combined = [my_ip_cidr] + [c for c in static if c != my_ip_cidr]
print(json.dumps(combined))
" "$STATIC_CIDRS_JSON" "${MY_IP}/32")

echo "==> Terminating the EMR cluster (terraform apply -var=emr_enabled=false)..."
terraform apply -var="emr_enabled=false" -var="allowed_cidrs=${ALLOWED_CIDRS_JSON}" "$@"

POSTGRES_ID=$(terraform output -raw postgres_identifier)
echo "==> Stopping RDS instance ${POSTGRES_ID}..."
aws rds stop-db-instance --db-instance-identifier "$POSTGRES_ID" >/dev/null 2>&1 \
  && echo "    stop requested" \
  || echo "    already stopped (or already stopping) — continuing"

echo
echo "Done. Note: AWS auto-restarts a stopped RDS instance after 7 days if left that long —"
echo "re-run this script if you notice it back up unexpectedly."
