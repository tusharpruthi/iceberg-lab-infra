# iceberg-lab-infra

Terraform for running [`flink-iceberg-playground`](../flink-iceberg-playground) against real AWS
infrastructure: RDS Postgres (source), AWS Glue (Iceberg catalog), S3 (warehouse), and an EMR
cluster running both Flink (the pipeline) and Trino (for querying the result later).

Built as a cost-constrained playground: **storage and catalog (S3, Glue, VPC, IAM) stay
always-on** (near-zero idle cost); **RDS is paused/resumed**, not destroyed, so your source data
survives between sessions; **EMR is fully terminated and recreated** each session, since it holds
no state that matters — everything durable lives in S3/Glue. See `PLAN.md` for the full design
rationale.

## First-time setup

1. Configure the AWS CLI with credentials that can create VPCs, RDS, S3, Glue, EMR, and IAM
   resources: `aws configure` (or `aws configure --profile iceberg-lab` if you manage multiple
   accounts — see `aws_profile` in `terraform.tfvars.example`). After `terraform apply`, confirm
   which account was actually used with `terraform output aws_account_id`.
2. Create an EC2 key pair for SSH access to the EMR master:
   ```bash
   aws ec2 create-key-pair --key-name iceberg-lab --query 'KeyMaterial' --output text > iceberg-lab.pem
   chmod 400 iceberg-lab.pem
   ```
3. `cp terraform.tfvars.example terraform.tfvars`, then fill in:
   - `allowed_cidrs` — a placeholder is fine here (e.g. leave the example value). On a dynamic-IP
     connection, `scripts/start.sh`/`stop.sh` fetch your *current* IP automatically and override
     this value on every run — it only matters if you run `terraform plan`/`apply` directly.
   - `ec2_key_pair_name` — the key pair name from step 2.
4. Both defaults below were verified against live AWS in `ap-south-1` (Mumbai) — re-check if you
   change `var.region`, since availability differs by region:
   - `postgres_engine_version` (`16.14`) — confirmed available via `aws rds
     describe-db-engine-versions --engine postgres --region ap-south-1`. An earlier default
     (`16.4`) was NOT available in this region and would have failed at apply time.
   - `emr_release_label` (`emr-7.13.0`) — confirmed via `aws emr describe-release-label` to ship
     **Flink 1.20.0**, an exact match with `flink-iceberg-playground`'s `pom.xml` `flink.version`.
     An earlier default (`emr-7.1.0`) shipped Flink 1.18.1 — a real mismatch, not a hypothetical
     one, caught before it could cause a classpath problem at job-submission time.
5. `terraform init`
6. `terraform plan` — review it. This is the point to catch anything unexpected before it's real,
   billed infrastructure.
7. `terraform apply` (with `emr_enabled` at its default `false`) — brings up RDS/S3/Glue/networking
   only. Cheap to leave running.

## Day to day

```bash
scripts/start.sh   # resumes RDS, brings up the EMR cluster, applies an idle auto-terminate safety net
scripts/stop.sh    # terminates the EMR cluster, pauses RDS
```

`scripts/start.sh` accepts extra `terraform apply` flags (e.g. `-auto-approve`) if you want to
skip the confirmation prompt once you trust the plan.

AWS auto-restarts a stopped RDS instance after 7 days if left stopped that long — if you notice
it's back up unexpectedly, just re-run `scripts/stop.sh`.

## Running the job

Terraform doesn't build or upload the jar — that's a manual/CI concern kept separate from infra:

```bash
cd ../flink-iceberg-playground
mvn package -DskipTests
aws s3 cp target/flink-iceberg-playground-1.0-SNAPSHOT.jar \
  "s3://$(cd ../iceberg-lab-infra && terraform output -raw warehouse_bucket_name)/jars/flink-iceberg-playground.jar"

cd ../iceberg-lab-infra
scripts/submit-job.sh "s3://$(terraform output -raw warehouse_bucket_name)/jars/flink-iceberg-playground.jar"
```

This is a **manual** trigger, on purpose — no scheduler is provisioned here. Run
`scripts/submit-job.sh` whenever you want a sync; the real every-5-minutes cadence is a later
production concern.

## Generating dummy WAL activity with `pg_cron`

`pg_cron` is enabled on the RDS parameter group so you can schedule inserts *inside* Postgres,
independent of whether EMR is up — changes just queue on the replication slot until the next time
you run the job. Connect to the instance (`psql -h $(terraform output -raw postgres_address) -U
playground -d playground`, password via `terraform output -raw postgres_master_password`) and
run something like:

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'dummy-orders',
  '*/2 * * * *',
  $$INSERT INTO orders (id, customer_id, amount, status)
    SELECT nextval('orders_id_seq'), (random() * 2 + 1)::int, (random() * 100)::numeric(10,2), 'PLACED'
    FROM generate_series(1, 1)$$
);
```

Adjust the table/column names to match whatever schema you've created — this repo doesn't own
that; it's the same schema `docker/postgres-init/01-sample-schema.sql` sets up locally.

## Querying with Trino

Trino runs on the same EMR cluster. SSH in and use its CLI, or use the Trino UI at
`http://<emr_master_public_dns>:8889` (only reachable from `allowed_cidrs`):

```bash
ssh -i iceberg-lab.pem hadoop@$(terraform output -raw emr_master_public_dns)
trino --catalog iceberg --schema public
```

## Cost estimate (ap-south-1 / Mumbai, approximate — verify with the AWS Pricing Calculator)

- **Idle** (EMR terminated, RDS stopped): S3 + Glue at playground scale ≈ **$0/mo**; RDS storage
  held while stopped (20GB gp3) ≈ **$2–2.50/mo** (us-east-1 rate carried over — Mumbai's exact
  RDS storage rate hasn't been confirmed) — the only cost that persists at rest.
- **Active** (RDS started + EMR up): RDS `db.t4g.micro` ≈ **$0.021/hr** (us-east-1 rate, Mumbai's
  RDS compute rate not yet confirmed); EMR `m5.xlarge` single node in Mumbai ≈ **$0.250/hr**
  (confirmed: $0.202 EC2 + $0.048 EMR fee); combined ≈ **$0.271/hr**. EMR supports neither
  burstable (T-family) instances nor anything smaller than `.xlarge` in any family — this is
  the smallest size EMR allows, not a conservative choice.
- **Rough monthly total**: light use (~20 hrs/mo) ≈ **$7.40–7.90**; heavy use (~100 hrs/mo) ≈ **$29.10–29.60**.
- If you want the RDS numbers confirmed for Mumbai specifically rather than carried over from
  us-east-1, check the RDS pricing page for `db.t4g.micro` in `ap-south-1`.
- The RDS master password is a plain `terraform.tfvars` value (gitignored, never committed) —
  $0/mo either way, but see `variables.tf`'s `postgres_master_password` for the trade this
  makes against the SSM/Secrets-Manager-based approaches that were tried and dropped first.

## Tearing everything down

```bash
scripts/stop.sh          # in case EMR is up
terraform destroy        # removes RDS, S3, Glue, networking, IAM too — irreversible, confirm you want this
```
