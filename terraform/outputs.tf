output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "aws_region" {
  description = "AWS region."
  value       = var.aws_region
}

output "ec2_public_ips" {
  description = "Public IPs by node name."
  value       = { for name, node in module.ec2 : name => node.public_ip }
}

output "ec2_private_ips" {
  description = "Private IPs by node name."
  value       = { for name, node in module.ec2 : name => node.private_ip }
}

output "rds_endpoint" {
  description = "RDS endpoint, if enabled."
  value       = var.create_rds ? module.rds[0].endpoint : null
}

output "alb_dns_name" {
  description = "ALB DNS name, if enabled."
  value       = var.enable_alb ? module.alb[0].dns_name : null
}

output "s3_bucket_names" {
  description = "Created S3 buckets."
  value       = keys(aws_s3_bucket.app)
}

output "ansible_inventory_hint" {
  description = "Command to generate a local Ansible inventory from Terraform output."
  value       = "terraform -chdir=terraform output -json > terraform-output.json && ./scripts/render-inventory.sh terraform-output.json ansible/inventory/dev.ini"
}
