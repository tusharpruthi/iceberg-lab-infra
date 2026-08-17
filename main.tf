module "networking" {
  source = "./modules/networking"

  project_name  = var.project_name
  allowed_cidrs = var.allowed_cidrs
}

module "storage" {
  source = "./modules/storage"

  project_name = var.project_name
}

module "postgres" {
  source = "./modules/postgres"

  project_name         = var.project_name
  subnet_ids           = module.networking.public_subnet_ids
  security_group_id    = module.networking.rds_security_group_id
  instance_class       = var.postgres_instance_class
  allocated_storage_gb = var.postgres_allocated_storage_gb
  engine_version       = var.postgres_engine_version
  db_name              = var.postgres_db_name
  username             = var.postgres_username
  master_password      = var.postgres_master_password
}

module "emr" {
  source = "./modules/emr"

  project_name          = var.project_name
  create                = var.emr_enabled
  region                = var.region
  release_label         = var.emr_release_label
  master_instance_type  = var.emr_master_instance_type
  subnet_id             = module.networking.public_subnet_id
  security_group_id     = module.networking.emr_security_group_id
  key_pair_name         = var.ec2_key_pair_name
  warehouse_bucket_name = module.storage.bucket_name
  warehouse_bucket_arn  = module.storage.bucket_arn
  glue_database_name    = module.storage.glue_database_name
}
