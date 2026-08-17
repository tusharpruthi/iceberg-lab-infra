output "cluster_id" {
  value = try(aws_emr_cluster.this[0].id, null)
}

output "master_public_dns" {
  value = try(aws_emr_cluster.this[0].master_public_dns, null)
}
