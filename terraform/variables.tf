variable "project" {
  description = "Project name used for resource naming."
  type        = string
  default     = "nexatech"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-southeast-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks."
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks."
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH into EC2 instances."
  type        = list(string)
  default     = []
}

variable "allowed_http_cidrs" {
  description = "CIDRs allowed to access public HTTP/HTTPS and exposed service ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "key_name" {
  description = "Existing EC2 key pair name. Leave null to use SSM Session Manager only."
  type        = string
  default     = null
}

variable "instance_ami_id" {
  description = "Optional AMI id override. Defaults to latest Ubuntu 24.04 LTS for selected architecture."
  type        = string
  default     = null
}

variable "instance_architecture" {
  description = "EC2 CPU architecture. Use x86_64 for Intel/AMD families such as t3, m7i-flex, and c7i-flex; use arm64 for Graviton families such as t4g."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.instance_architecture)
    error_message = "instance_architecture must be arm64 or x86_64."
  }
}

variable "infra_instance_type" {
  description = "Instance type for infra services."
  type        = string
  default     = "t4g.medium"
}

variable "app1_instance_type" {
  description = "Instance type for core app services."
  type        = string
  default     = "t4g.medium"
}

variable "enable_app2" {
  description = "Create the optional app-2 instance."
  type        = bool
  default     = false
}

variable "app2_instance_type" {
  description = "Instance type for optional app-2 services."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size for EC2 instances."
  type        = number
  default     = 40
}

variable "create_rds" {
  description = "Whether to create a low-cost RDS PostgreSQL instance."
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS storage in GB."
  type        = number
  default     = 20
}

variable "rds_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.3"
}

variable "rds_database_name" {
  description = "Initial PostgreSQL database name."
  type        = string
  default     = "nexatech"
}

variable "rds_username" {
  description = "RDS master username."
  type        = string
  default     = "nexatech"
}

variable "rds_password" {
  description = "RDS master password."
  type        = string
  sensitive   = true
}

variable "enable_alb" {
  description = "Create a public ALB for api-gateway."
  type        = bool
  default     = true
}

variable "certificate_arn" {
  description = "Optional ACM certificate ARN for HTTPS listener."
  type        = string
  default     = null
}

variable "s3_buckets" {
  description = "S3 buckets for storage/news static objects. Names must be globally unique."
  type        = list(string)
  default     = []
}
