# Minimal networking: one VPC, one public subnet, no NAT gateway. Nothing here needs
# outbound-only private routing, and a NAT gateway's ~$32/mo fixed cost would dominate a
# playground budget for no benefit.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public"
  }
}

# RDS DB subnet groups require subnets in at least 2 different AZs even for a single-AZ instance
# — this second subnet exists only to satisfy that, EMR always uses the first one. Still no NAT
# gateway; both are public subnets on the same route table.
resource "aws_subnet" "public_secondary" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_secondary_cidr
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-secondary"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_secondary" {
  subnet_id      = aws_subnet.public_secondary.id
  route_table_id = aws_route_table.public.id
}

# EMR master: SSH, Flink Web UI (via YARN ResourceManager proxy), Trino UI, all restricted to
# var.allowed_cidrs. Egress open — EMR needs to reach S3, Glue, and package repos.
resource "aws_security_group" "emr" {
  name        = "${var.project_name}-emr"
  description = "EMR primary node: SSH/Flink-UI/Trino-UI from allowed_cidrs only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "YARN ResourceManager UI (Flink job UIs proxy through this)"
    from_port   = 8088
    to_port     = 8088
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "Trino coordinator UI"
    from_port   = 8889
    to_port     = 8889
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-emr"
  }
}

# Postgres: reachable only from the EMR security group, never directly from allowed_cidrs.
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "Postgres: reachable only from the EMR security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from EMR"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.emr.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds"
  }
}
