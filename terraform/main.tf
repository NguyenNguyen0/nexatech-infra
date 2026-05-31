locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  arch_to_ami_arch = {
    "x86_64" = "amd64"
    "arm64"  = "arm64"
  }
  ami_arch = local.arch_to_ami_arch[var.instance_architecture]

  ec2_instances = merge(
    {
      infra-1 = {
        instance_type = var.infra_instance_type
        role          = "infra"
        compose_file  = "infra.docker-compose.yml"
      }
      app-1 = {
        instance_type = var.app1_instance_type
        role          = "app"
        compose_file  = "app-1.docker-compose.yml"
      }
    },
    var.enable_app2 ? {
      app-2 = {
        instance_type = var.app2_instance_type
        role          = "app"
        compose_file  = "app-2.docker-compose.yml"
      }
    } : {}
  )
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  count       = var.instance_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = [var.instance_architecture]
  }
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host_header" {
  name = "Managed-AllViewerExceptHostHeader"
}

module "vpc" {
  source = "./modules/vpc"

  name                 = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = slice(data.aws_availability_zones.available.names, 0, length(var.public_subnet_cidrs))
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "iam" {
  source = "./modules/iam"

  name = local.name_prefix
}

resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2"
  description = "Access for NexaTech EC2 nodes"
  vpc_id      = module.vpc.vpc_id

  dynamic "ingress" {
    for_each = length(var.allowed_ssh_cidrs) > 0 ? [1] : []

    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_ssh_cidrs
    }
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_http_cidrs
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_http_cidrs
  }

  ingress {
    description = "API gateway direct access"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_http_cidrs
  }

  ingress {
    description = "Kong proxy direct access"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = var.allowed_http_cidrs
  }

  ingress {
    description = "Service mesh within VPC"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Outbound internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "ec2" {
  source = "./modules/ec2"

  for_each = local.ec2_instances

  name                 = "${local.name_prefix}-${each.key}"
  ami_id               = var.instance_ami_id != null ? var.instance_ami_id : data.aws_ami.ubuntu[0].id
  instance_type        = each.value.instance_type
  key_name             = var.key_name
  subnet_id            = module.vpc.public_subnet_ids[index(keys(local.ec2_instances), each.key) % length(module.vpc.public_subnet_ids)]
  security_group_ids   = [aws_security_group.ec2.id]
  iam_instance_profile = module.iam.instance_profile_name
  root_volume_size_gb  = var.root_volume_size_gb

  tags = {
    Name        = "${local.name_prefix}-${each.key}"
    ServiceRole = each.value.role
    ComposeFile = each.value.compose_file
  }
}

resource "aws_security_group" "rds" {
  count       = var.create_rds ? 1 : 0
  name        = "${local.name_prefix}-rds"
  description = "PostgreSQL access from NexaTech EC2 nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from app nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    description = "Outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "rds" {
  count  = var.create_rds ? 1 : 0
  source = "./modules/rds"

  name               = local.name_prefix
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [aws_security_group.rds[0].id]
  instance_class     = var.rds_instance_class
  allocated_storage  = var.rds_allocated_storage
  engine_version     = var.rds_engine_version
  database_name      = var.rds_database_name
  username           = var.rds_username
  password           = var.rds_password
}

module "alb" {
  count  = var.enable_alb ? 1 : 0
  source = "./modules/alb"

  name               = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.public_subnet_ids
  allowed_cidrs      = var.allowed_http_cidrs
  target_instance_id = module.ec2["infra-1"].instance_id
  target_port        = 8000
  certificate_arn    = var.certificate_arn
}

resource "aws_cloudfront_distribution" "api" {
  count = var.enable_alb && var.enable_cloudfront_api ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name_prefix} API HTTPS proxy"
  price_class         = "PriceClass_100"
  wait_for_deployment = false

  origin {
    domain_name = module.alb[0].dns_name
    origin_id   = "${local.name_prefix}-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "${local.name_prefix}-alb"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header.id
    compress                 = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

resource "aws_s3_bucket" "app" {
  for_each = toset(var.s3_buckets)

  bucket = each.value
}

resource "aws_s3_bucket_public_access_block" "app" {
  for_each = aws_s3_bucket.app

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  for_each = aws_s3_bucket.app

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
