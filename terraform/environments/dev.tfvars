project     = "nexatech"
environment = "dev"
aws_region  = "ap-southeast-1"

vpc_cidr             = "10.20.0.0/16"
public_subnet_cidrs  = ["10.20.1.0/24", "10.20.2.0/24"]
private_subnet_cidrs = ["10.20.11.0/24", "10.20.12.0/24"]

# Replace with your office/home IP, for example ["203.0.113.10/32"].
allowed_ssh_cidrs = []

# For production, keep this open only through ALB/CloudFront or known CIDRs.
allowed_http_cidrs = ["0.0.0.0/0"]

# Existing EC2 key pair. Leave null if you use SSM Session Manager.
key_name = null

instance_architecture = "arm64"
infra_instance_type   = "t4g.medium"
app1_instance_type    = "t4g.medium"
enable_app2           = false
app2_instance_type    = "t4g.small"
root_volume_size_gb   = 40

create_rds            = true
rds_instance_class    = "db.t4g.micro"
rds_allocated_storage = 20
rds_engine_version    = "16.3"
rds_database_name     = "nexatech"
rds_username          = "nexatech"
rds_password          = "CHANGE_ME_USE_TFVARS_OR_TF_VAR"

enable_alb      = true
certificate_arn = null

# Bucket names must be globally unique. Example:
# s3_buckets = ["nexatech-dev-storage-yourname", "nexatech-dev-news-yourname"]
s3_buckets = []
