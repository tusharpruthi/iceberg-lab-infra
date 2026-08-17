# Every resource in this module is gated on var.create so the whole module resolves to nothing
# when the cluster is off — no IAM churn benefit either way, but it keeps "EMR enabled" a single,
# legible on/off switch rather than "cluster off, roles still hanging around."

data "aws_iam_policy_document" "emr_service_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["elasticmapreduce.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "emr_service_role" {
  count              = var.create ? 1 : 0
  name               = "${var.project_name}-emr-service-role"
  assume_role_policy = data.aws_iam_policy_document.emr_service_assume_role.json
}

resource "aws_iam_role_policy_attachment" "emr_service_role" {
  count      = var.create ? 1 : 0
  role       = aws_iam_role.emr_service_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceRole"
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "emr_ec2_role" {
  count              = var.create ? 1 : 0
  name               = "${var.project_name}-emr-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "emr_ec2_role" {
  count      = var.create ? 1 : 0
  role       = aws_iam_role.emr_ec2_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
}

# Least-privilege on top of the baseline EMR EC2 policy: read/write on the one warehouse bucket,
# and the Glue Data Catalog actions Iceberg needs on the one Glue database (and its tables) — no
# glue:CreateDatabase, since modules/storage already pre-creates it.
data "aws_iam_policy_document" "emr_ec2_iceberg_access" {
  statement {
    sid    = "WarehouseBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      var.warehouse_bucket_arn,
      "${var.warehouse_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "GlueIcebergCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
      "glue:BatchGetPartition",
      "glue:BatchDeletePartition",
    ]
    resources = [
      "arn:aws:glue:${var.region}:*:catalog",
      "arn:aws:glue:${var.region}:*:database/${var.glue_database_name}",
      "arn:aws:glue:${var.region}:*:table/${var.glue_database_name}/*",
    ]
  }

}

resource "aws_iam_role_policy" "emr_ec2_iceberg_access" {
  count  = var.create ? 1 : 0
  name   = "${var.project_name}-iceberg-access"
  role   = aws_iam_role.emr_ec2_role[0].id
  policy = data.aws_iam_policy_document.emr_ec2_iceberg_access.json
}

resource "aws_iam_instance_profile" "emr_ec2" {
  count = var.create ? 1 : 0
  name  = "${var.project_name}-emr-ec2-profile"
  role  = aws_iam_role.emr_ec2_role[0].name
}

# Trino's Iceberg-on-Glue catalog, configured declaratively via EMR's configuration
# classifications rather than a bootstrap action editing files by hand. Verify the exact
# classification name ("trino-connector-<catalog-name>") against current EMR docs for
# var.release_label before first apply — this convention has shifted across EMR versions.
locals {
  emr_configurations = jsonencode([
    {
      Classification = "trino-connector-iceberg"
      Properties = {
        "connector.name" = "iceberg"
        "hive.metastore" = "glue"
      }
    }
  ])
}

resource "aws_emr_cluster" "this" {
  count         = var.create ? 1 : 0
  name          = "${var.project_name}-cluster"
  release_label = var.release_label
  applications  = ["Hadoop", "Flink", "Trino"]

  service_role         = aws_iam_role.emr_service_role[0].arn
  log_uri              = "s3://${var.warehouse_bucket_name}/emr-logs/"
  configurations_json   = local.emr_configurations
  termination_protection = false

  # No steps run automatically — jobs are submitted manually via scripts/submit-job.sh, so the
  # cluster must stay up between submissions instead of terminating the moment it's briefly idle.
  keep_job_flow_alive_when_no_steps = true

  ec2_attributes {
    subnet_id                        = var.subnet_id
    additional_master_security_groups = var.security_group_id
    key_name                          = var.key_pair_name
    instance_profile                  = aws_iam_instance_profile.emr_ec2[0].arn
  }

  master_instance_group {
    instance_type = var.master_instance_type
  }

  # Idle auto-termination (safety net against forgetting scripts/stop.sh) is applied via
  # `aws emr put-auto-termination-policy` in scripts/start.sh right after this cluster comes up,
  # not as inline HCL here — the aws_emr_cluster resource's support for this varies enough across
  # provider versions that it's safer to apply it with a plain CLI call than guess the current
  # block schema. See var.idle_timeout_minutes for the value it uses.

  tags = {
    Name = "${var.project_name}-cluster"
  }
}
