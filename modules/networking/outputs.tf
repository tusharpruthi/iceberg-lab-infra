output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "Primary public subnet — where the EMR cluster is placed."
  value       = aws_subnet.public.id
}

output "public_subnet_ids" {
  description = "Both public subnets, across 2 AZs — used for the RDS DB subnet group."
  value       = [aws_subnet.public.id, aws_subnet.public_secondary.id]
}

output "availability_zone" {
  value = aws_subnet.public.availability_zone
}

output "emr_security_group_id" {
  value = aws_security_group.emr.id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}
