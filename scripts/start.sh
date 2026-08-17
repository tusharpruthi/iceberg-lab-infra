#!/usr/bin/env bash
# Starts the RDS instance (resumes existing data/schema — never recreated) and brings the EMR
# cluster up via Terraform. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-60}"

# Most home/mobile ISPs hand out dynamic IPs, so a fixed allowed_cidrs in terraform.tfvars would
# go stale between sessions. Fetch the current IP fresh every time, and merge it with
# static_allowed_cidrs (e.g. a company VPN's NAT egress IP) — that way a static entry survives
# every run without being overwritten by this dynamic one.
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
echo "==> Allowed CIDRs this session: ${ALLOWED_CIDRS_JSON}"

POSTGRES_ID=$(terraform output -raw postgres_identifier)
echo "==> Starting RDS instance ${POSTGRES_ID}..."
aws rds start-db-instance --db-instance-identifier "$POSTGRES_ID" >/dev/null 2>&1 \
  && echo "    start requested" \
  || echo "    already started (or already starting) — continuing"

echo "==> Bringing up the EMR cluster (terraform apply -var=emr_enabled=true)..."
terraform apply -var="emr_enabled=true" -var="allowed_cidrs=${ALLOWED_CIDRS_JSON}" "$@"

CLUSTER_ID=$(terraform output -raw emr_cluster_id)
echo "==> Waiting for cluster ${CLUSTER_ID} to reach RUNNING/WAITING..."
aws emr wait cluster-running --cluster-id "$CLUSTER_ID" || \
  echo "    (wait timed out or the waiter isn't available in your CLI version — check manually: aws emr describe-cluster --cluster-id ${CLUSTER_ID})"

echo "==> Applying idle auto-termination safety net (${IDLE_TIMEOUT_MINUTES} min)..."
aws emr put-auto-termination-policy \
  --cluster-id "$CLUSTER_ID" \
  --auto-termination-policy "IdleTimeout=$(( IDLE_TIMEOUT_MINUTES * 60 ))" \
  || echo "    (put-auto-termination-policy failed — not fatal, but the cluster will only stop via scripts/stop.sh now)"

echo
echo "Cluster master DNS: $(terraform output -raw emr_master_public_dns)"
echo "RDS may still be starting — check with:"
echo "  aws rds describe-db-instances --db-instance-identifier ${POSTGRES_ID} --query 'DBInstances[0].DBInstanceStatus'"
