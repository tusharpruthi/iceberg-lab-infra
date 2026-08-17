variable "region" {
  description = "AWS region for everything in this stack."
  type        = string
  default     = "ap-south-1" # Mumbai
}

variable "project_name" {
  description = "Short name used to tag and prefix every resource this stack creates."
  type        = string
  default     = "iceberg-lab"
}

variable "aws_profile" {
  description = <<-EOT
    Named AWS CLI profile to authenticate as (e.g. from `aws configure --profile <name>`).
    Leave as "" (the default) to fall back to whatever credentials are already active in your
    shell (env vars, default profile, SSO session, etc.) — set this explicitly if you manage
    multiple AWS accounts and want this repo to always target a specific one regardless of
    ambient shell state. Check `terraform output aws_account_id` after any plan/apply to confirm
    which account was actually used.
  EOT
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the EMR master's SSH (22), Flink Web UI (8088), and Trino UI (8889)
    ports. A list — there is deliberately no permissive default here. Typically holds two kinds
    of entries: your own current IP as a /32 (kept fresh automatically — scripts/start.sh and
    scripts/stop.sh fetch it live and merge it into this list on every run, so a dynamic-IP
    connection never goes stale) and any static IPs that should always have access regardless of
    who's connecting, e.g. a company VPN's NAT egress IP. Only relevant to set by hand if you run
    `terraform plan`/`apply` directly instead of through those scripts.
  EOT
  type        = list(string)
}

variable "static_allowed_cidrs" {
  description = <<-EOT
    Static CIDRs that should always be allowed, independent of your own current IP — e.g. a
    company VPN's NAT egress IP (see the Pritunl discussion in PLAN.md). scripts/start.sh and
    scripts/stop.sh combine this list with your freshly-fetched current IP to build the full
    allowed_cidrs list, so a static entry here survives every script run without being
    overwritten. Empty by default — nothing static is allowed until you add something.
  EOT
  type        = list(string)
  default     = []
}

variable "ec2_key_pair_name" {
  description = <<-EOT
    Name of an EC2 key pair that already exists in this AWS account/region, used for SSH access
    to the EMR master node. Create one first with:
      aws ec2 create-key-pair --key-name iceberg-lab --query 'KeyMaterial' --output text > iceberg-lab.pem
  EOT
  type        = string
}

variable "emr_enabled" {
  description = <<-EOT
    Whether the EMR cluster should exist. false (the default) terminates/omits it entirely — the
    dominant cost of this stack, and the piece meant to be off between sessions. Toggle with
    scripts/start.sh / scripts/stop.sh rather than editing this directly.
  EOT
  type        = bool
  default     = false
}

variable "emr_release_label" {
  description = <<-EOT
    EMR release label to use. Confirmed via `aws emr describe-release-label --release-label
    emr-7.13.0 --region ap-south-1`: ships Flink 1.20.0 (exact match with
    flink-iceberg-playground's pom.xml flink.version), Hadoop 3.4.2, Trino 479. An earlier
    default here (emr-7.1.0) shipped Flink 1.18.1 — a real mismatch against the jar, not a
    hypothetical one — caught by actually checking before first apply. Re-verify if you ever
    change var.region, since availability differs by region.
  EOT
  type        = string
  default     = "emr-7.13.0"
}

variable "emr_master_instance_type" {
  description = <<-EOT
    Instance type for the EMR primary (and only) node. Confirmed against EMR's own supported-
    instance-types doc (https://docs.aws.amazon.com/emr/latest/ManagementGuide/emr-supported-instance-types.html):
    EMR does not support T-family (burstable) instances at all, and .xlarge is the smallest size
    supported in ANY family — there is no EMR-supported instance smaller than .xlarge, so no size
    reduction below m5.xlarge is possible. Cost reduction from here would have to come from a
    cheaper processor family at the same .xlarge size (e.g. Graviton's m6g.xlarge, confirmed
    present in EMR's supported list, typically priced lower than m5.xlarge) or an AWS "Flex"
    instance type (e.g. m7i-flex.xlarge, also confirmed present) built for workloads that don't
    need sustained full CPU — neither has been benchmarked or price-compared here, so m5.xlarge
    stays the default until one of those is actually evaluated.
  EOT
  type        = string
  default     = "m5.xlarge"
}

variable "postgres_instance_class" {
  description = "RDS instance class for the Postgres source database."
  type        = string
  default     = "db.t4g.micro"
}

variable "postgres_allocated_storage_gb" {
  description = "RDS allocated storage in GB."
  type        = number
  default     = 20
}

variable "postgres_engine_version" {
  description = <<-EOT
    Postgres engine version. Confirmed available in ap-south-1 (Mumbai) as of this writing via
    `aws rds describe-db-engine-versions --engine postgres --region ap-south-1`, which listed
    16.9 through 16.14 — 16.4 (an earlier default here) is NOT available in this region and
    would fail at apply time. Re-check if you change var.region.
  EOT
  type        = string
  default     = "16.14"
}

variable "postgres_db_name" {
  description = "Initial database name created on the RDS instance."
  type        = string
  default     = "playground"
}

variable "postgres_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "playground"
}

variable "postgres_master_password" {
  description = <<-EOT
    RDS master password, as a plain value. Set via terraform.tfvars (gitignored) — never given a
    default here, never committed. Playground simplification: an earlier design generated this
    randomly and stored it in SSM Parameter Store, fetched at runtime by the EMR role; that was
    dropped in favor of this plain variable, on the basis that this stack holds disposable test
    data, not real sensitive data. If that assumption stops holding, reintroducing SSM (or
    Secrets Manager) storage is the fix — PLAN.md has the fuller reasoning from when that
    version existed.
  EOT
  type        = string
  sensitive   = true
}

variable "postgres_replication_tables" {
  description = "Comma-separated table names to include in the logical replication publication (matches the app's POSTGRES_TABLES config)."
  type        = string
  default     = "orders,customers"
}
