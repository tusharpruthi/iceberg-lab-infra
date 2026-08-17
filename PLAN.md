# Iceberg Lab Infra — Implementation Plan

## Context

`flink-iceberg-playground` currently only runs locally (Docker Compose: Postgres+wal2json, MinIO,
a REST catalog, a Flink cluster). This repo provisions the same pipeline against real AWS
infrastructure — RDS Postgres, AWS Glue as the Iceberg catalog, S3 as the warehouse, and an EMR
cluster running both Flink and Trino — for a **cost-constrained playground**: start it up only
when actively working with it, pay as little as possible the rest of the time.

The app's production config (`application-prod.yml` in `flink-iceberg-playground`) is the contract
this infra must satisfy — these env vars, and only these, need to resolve at job-submission time:
`POSTGRES_HOST/PORT/DATABASE/USERNAME/PASSWORD/SLOT_NAME/PUBLICATION_NAME/TABLES`,
`ICEBERG_CATALOG_NAME` (default `glue_catalog`), `ICEBERG_WAREHOUSE`, `AWS_REGION`. Catalog type is
already hardcoded to `glue` in that file — nothing here needs to touch app code.

## Decisions already made (do not re-litigate without asking)

- Trino runs on the **same** EMR cluster as Flink — one cluster, both applications installed.
- Postgres is **RDS**, smallest instance class (`db.t4g.micro`).
- A new, minimal, dedicated **VPC** in **ap-south-1 (Mumbai)**: one public subnet, no NAT gateway (its
  ~$32/mo fixed cost buys nothing here — nothing needs outbound-only private routing).
- **Storage/catalog stay always-on** (S3, Glue, VPC, IAM — near-zero idle cost); **only compute is
  toggled**.
- **EMR is terminated, not paused, when idle** — it holds no state that matters (Iceberg data
  lives in S3, catalog metadata in Glue), and EMR doesn't support stop/start anyway, only
  terminate/create. Toggled via Terraform: `count = var.emr_enabled ? 1 : 0`.
- **RDS is stopped via AWS CLI, never destroyed** — it holds the actual source tables the pipeline
  reads from; destroying it every session would wipe them, defeating the point of stable source
  data to iterate against. Always present as a Terraform resource; paused with `aws rds
  stop-db-instance` / resumed with `start-db-instance`. AWS auto-restarts a stopped instance after
  7 days — re-run `stop.sh` if that happens, no automation needed for a playground.
- `pg_cron` is enabled on the RDS parameter group so dummy data can be generated **inside**
  Postgres on a schedule, independent of whether EMR is up — WAL activity queues on the
  replication slot regardless, ready whenever the Flink job next runs. A starter SQL snippet goes
  in the README; this is not a full data-generator subsystem.
- No CI/CD, no automatic recurring job trigger, no remote Terraform state backend, no Trino result
  consumption (BI tool, JDBC client) — all explicitly out of scope for this pass.

## Repo layout

```
iceberg-lab-infra/
├── PLAN.md                      # this file
├── README.md                    # start/stop instructions, cost notes, first-time setup
├── versions.tf                  # terraform + aws provider version constraints
├── providers.tf                 # aws provider, region var
├── variables.tf                 # root variables (region, allowed_cidrs, emr_enabled, instance sizes)
├── main.tf                      # wires modules together
├── outputs.tf                   # RDS endpoint, S3 bucket, Glue DB name, EMR master DNS (when up)
├── terraform.tfvars.example     # copy to terraform.tfvars, fill in allowed_cidrs / key pair name
├── modules/
│   ├── networking/               # VPC, public subnet, IGW, route table, security groups
│   ├── storage/                  # S3 warehouse bucket + Glue Catalog Database ("iceberg_lab")
│   ├── postgres/                 # RDS instance, parameter group, plain master_password variable
│   └── emr/                      # EMR cluster, IAM, Trino Iceberg-on-Glue configuration
└── scripts/
    ├── start.sh                  # aws rds start-db-instance + terraform apply -var=emr_enabled=true
    ├── stop.sh                   # aws rds stop-db-instance + terraform apply -var=emr_enabled=false
    └── submit-job.sh             # aws emr add-steps: runs the jar with prod env vars
```

## Steps

Work through in order; each step's done-condition is the file(s) existing and `terraform validate`
passing for anything that adds `.tf` files (run validate once at the end, not after every step —
module interdependencies mean early modules won't validate standalone until `main.tf` wires them).

1. **Root scaffold** — `versions.tf` (terraform >=1.7, aws provider ~>5.50), `providers.tf`,
   `variables.tf` (`region` default `ap-south-1`/Mumbai; `allowed_cidrs` no default, required;
   `emr_enabled` bool default `false`; `project_name` default `iceberg-lab`;
   `ec2_key_pair_name` no default, required — must already exist in the AWS account),
   `terraform.tfvars.example`. Done: files exist, root variables cover everything the modules
   below need from the caller.

2. **`modules/networking`** — VPC, one public subnet, internet gateway, route table, three
   security groups: `emr_sg` (SSH/Trino-UI/Flink-UI from `var.allowed_cidrs` only), `rds_sg`
   (Postgres 5432 from `emr_sg` only, nothing else), a bastion-less design (EMR master itself is
   the SSH entrypoint). Outputs: `vpc_id`, `public_subnet_id`, `emr_sg_id`, `rds_sg_id`. Done:
   outputs exposed, no hardcoded CIDR wider than `var.allowed_cidrs`.

3. **`modules/storage`** — one S3 bucket (versioning off, lifecycle rule aborting incomplete
   multipart uploads after 1 day, block-public-access on), one `aws_glue_catalog_database` named
   to match the app's `public` schema. Outputs: `bucket_name`, `warehouse_path` (`s3://<bucket>/warehouse`),
   `glue_database_name`. Done: outputs match what `ICEBERG_WAREHOUSE`/`ICEBERG_CATALOG_NAME` need.

4. **`modules/postgres`** — `aws_db_instance` (`db.t4g.micro`, `postgres` 16.x, 20GB gp3), master
   password from a plain `var.master_password` (sensitive, no default, set via `terraform.tfvars`
   — gitignored, never committed). Two earlier designs were tried and dropped here, in order:
   RDS-managed password in Secrets Manager ($0.40/mo), then a Terraform-generated
   `random_password` stored in an SSM Parameter Store SecureString ($0/mo but added an IAM
   `ssm:GetParameter`/`kms:Decrypt` policy and an on-cluster fetch step). Both were replaced by
   this plain-variable approach on explicit request — this stack only ever holds disposable test
   data, and the added machinery wasn't worth it for that. The trade made explicit: the password
   now sits in Terraform state and gets embedded directly in `submit-job.sh`'s `aws emr
   add-steps` call (visible via `aws emr describe-step`) — acceptable for this repo's stated use,
   revisit if that assumption changes. A custom `aws_db_parameter_group` setting
   `rds.logical_replication = 1` and `shared_preload_libraries` including `pg_cron`, placed in
   the networking module's subnet + `rds_sg`. Outputs: `endpoint`, `port`, `db_name`,
   `master_password` (sensitive). Done: parameter group forces the reboot Terraform needs to
   apply static params.

5. **`modules/emr`** — `count = var.emr_enabled ? 1 : 0` on the cluster resource itself. IAM: one
   EC2 instance role scoped to `s3:*` on the warehouse bucket and `glue:*` on the one Glue
   database, plus AWS's standard managed EMR service-role and instance-profile policies. Cluster:
   single primary node (no core/task groups), `m5.xlarge` (4 vCPU, 16GB). Confirmed against
   [AWS's supported-instance-types doc](https://docs.aws.amazon.com/emr/latest/ManagementGuide/emr-supported-instance-types.html):
   EMR does not support T-family/burstable instances at all, and `.xlarge` is the smallest size
   supported in *any* family — there is no EMR-supported instance smaller than this, so
   `m5.xlarge` is the floor, not a conservative starting guess. (Earlier passes through this plan
   wrongly proposed `t3.large`, then `m5.large`, before either was checked against this doc —
   both corrected.) A cheaper *processor family* at the same `.xlarge` size — Graviton's
   `m6g.xlarge`, or an AWS "Flex" type like `m7i-flex.xlarge` (built for workloads that don't need
   sustained full CPU, which fits this one) — is a real further cost lever, confirmed present in
   EMR's supported list, but not benchmarked or price-compared here. Flink + Trino applications,
   `configurations` JSON setting Trino's Iceberg catalog (`connector.name=iceberg`,
   `hive.metastore=glue`) pointed at the storage module's bucket/database, `ec2_attributes` using
   `var.ec2_key_pair_name` and the networking module's subnet/`emr_sg`. **Update after live
   verification**: the Flink-version risk flagged here was real — `emr_release_label`'s original
   default (`emr-7.1.0`) ships Flink 1.18.1, a genuine mismatch against the jar's Flink 1.20.0.
   Checked live against `ap-south-1` via `aws emr list-release-labels` +
   `describe-release-label`; `emr-7.13.0` ships Flink 1.20.0 exactly, and is now the default.
   Re-verify if `var.region` ever changes. Done: EMR module resolves to zero resources when
   `emr_enabled=false`, full cluster when `true`.

6. **`main.tf` + `outputs.tf`** — wire the four modules together (storage/postgres/networking
   always created; emr conditional), root outputs surfacing everything `scripts/submit-job.sh`
   needs (RDS endpoint, secret ARN, warehouse path, Glue DB name, EMR master public DNS when up).
   Done: `terraform validate` passes at the root.

7. **`scripts/start.sh` / `stop.sh` / `submit-job.sh`** — `start.sh` runs `aws rds
   start-db-instance` then `terraform apply -var=emr_enabled=true`; `stop.sh` reverses the order
   (`terraform apply -var=emr_enabled=false` then `aws rds stop-db-instance`, since you want RDS
   reachable while EMR is still shutting down any in-flight job). `submit-job.sh` reads Terraform
   outputs directly, including the DB password (`terraform output -raw postgres_master_password`),
   and embeds it into the step it submits — no on-cluster fetch step, no extra IAM permissions for
   this. `submit-job.sh` calls `aws emr add-steps` running `flink run -c
   com.hevo.icebergplayground.job.IcebergWalSyncJob <jar-s3-path> prod` with those env vars
   exported first. Done: no script embeds a credential; each is idempotent to re-run.

8. **`README.md`** — first-time setup (create the EC2 key pair, set `allowed_cidrs`, `terraform
   init`), day-to-day start/stop, the cost estimate below, the EMR/Flink version-check caveat from
   step 5, and the `pg_cron` starter snippet for generating dummy WAL activity. Done: a first-time
   reader can go from nothing to a running job without asking a question this doc should answer.

9. **Validate** — `terraform init && terraform fmt -check && terraform validate` at the root.
   Do **not** run `plan`/`apply` against real AWS without the user explicitly asking for it —
   this provisions real, billed infrastructure.

## Reference

### Env var contract (from `application-prod.yml`)

| Var | Source |
|---|---|
| `POSTGRES_HOST` / `PORT` / `DATABASE` | `modules/postgres` outputs |
| `POSTGRES_USERNAME` / `PASSWORD` | fixed username; password from `var.postgres_master_password`, resolved locally by `submit-job.sh` |
| `POSTGRES_SLOT_NAME` / `PUBLICATION_NAME` / `TABLES` | fixed by the app's config, not infra-owned |
| `ICEBERG_CATALOG_NAME` | `glue_catalog` (the app's own default — no override needed) |
| `ICEBERG_WAREHOUSE` | `modules/storage` output `warehouse_path` |
| `AWS_REGION` | root `var.region` |

### Cost estimate (ap-south-1 / Mumbai, approximate — verify with the AWS Pricing Calculator)

**Idle** (EMR terminated, RDS stopped): S3 + Glue at playground scale ≈ **$0/mo**; RDS storage
held while stopped (20GB gp3) ≈ **$2–2.50/mo** (us-east-1 rate carried over, Mumbai's exact rate
unconfirmed) — the only cost that persists at rest.

**Active** (RDS started + EMR up): RDS `db.t4g.micro` ≈ **$0.021/hr** (us-east-1 rate, Mumbai's
RDS compute rate unconfirmed); EMR `m5.xlarge` single node in Mumbai ≈ **$0.250/hr** (confirmed:
$0.202 EC2 + $0.048 EMR fee); combined ≈ **$0.271/hr**.

**Rough monthly total**: light use (~20 hrs/mo) ≈ **$7.40–7.90**; heavy use (~100 hrs/mo) ≈
**$29.10–29.60**. EMR is the dominant active-use cost — why it's the piece fully terminated between
sessions, not paused.

### Explicitly out of scope this pass

CI/CD for the jar, an automatic recurring job trigger, a remote Terraform state backend, and Trino
result consumption (BI tool, JDBC client). Revisit only if asked.
