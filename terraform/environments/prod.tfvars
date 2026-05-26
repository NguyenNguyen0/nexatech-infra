project     = "nexatech"
environment = "prod"
aws_region  = "ap-southeast-1"

vpc_cidr             = "10.30.0.0/16"
public_subnet_cidrs  = ["10.30.1.0/24", "10.30.2.0/24"]
private_subnet_cidrs = ["10.30.11.0/24", "10.30.12.0/24"]

allowed_ssh_cidrs  = []
allowed_http_cidrs = ["0.0.0.0/0"]

key_name = null

instance_architecture = "arm64"
infra_instance_type   = "t4g.medium"
app1_instance_type    = "t4g.medium"
enable_app2           = true
app2_instance_type    = "t4g.small"
root_volume_size_gb   = 60

create_rds            = true
rds_instance_class    = "db.t4g.micro"
rds_allocated_storage = 30
rds_engine_version    = "16.3"
rds_database_name     = "nexatech"
rds_username          = "nexatech"
rds_password          = "CHANGE_ME_USE_TFVARS_OR_TF_VAR"

enable_alb      = true
certificate_arn = null

s3_buckets = []
