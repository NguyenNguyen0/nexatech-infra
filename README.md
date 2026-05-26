# NexaTech Infra

Low-cost AWS infrastructure for NexaTech backend.

## What This Provisions

- VPC with public/private subnets.
- EC2 nodes:
  - `infra-1`: discovery-server, config-server, api-gateway, Keycloak, Kafka.
  - `app-1`: core Java services.
  - optional `app-2`: shipping, news, audit, chat, storage, promotion, Python services.
- ECR repositories for all services.
- Optional RDS PostgreSQL.
- Optional public ALB routing to `api-gateway`.
- Optional private S3 buckets for storage/news assets.

## Prerequisites

- Terraform >= 1.6
- Ansible
- AWS credentials with permissions for EC2, VPC, IAM, ECR, RDS, ALB, and S3
- `jq` for `scripts/render-inventory.sh`

## Deploy Dev

Edit `terraform/environments/dev.tfvars` first:

- set `rds_password`
- set `allowed_ssh_cidrs` if you want SSH access
- set `key_name` if you use an EC2 key pair
- set globally unique `s3_buckets` if storage/news should use S3
- keep `instance_architecture = "arm64"` for `t4g.*`; your application images must be multi-arch or arm64

Then run:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -var-file=environments/dev.tfvars
terraform -chdir=terraform apply -var-file=environments/dev.tfvars
terraform -chdir=terraform output -json > terraform-output.json
./scripts/render-inventory.sh terraform-output.json ansible/inventory/dev.ini
```

Set `ecr_registry` and `image_tag` in `ansible/inventory/dev.ini`.

Copy env templates to each EC2 under `/opt/nexatech/env/` and fill real values:

```bash
scp env-templates/*.env.example ubuntu@INFRA_PUBLIC_IP:/tmp/
```

Each service expects a file named without `.example`, for example:

```text
/opt/nexatech/env/api-gateway.env
/opt/nexatech/env/identity-service.env
```

Deploy:

```bash
ansible-playbook -i ansible/inventory/dev.ini ansible/playbooks/deploy-infra.yml
ansible-playbook -i ansible/inventory/dev.ini ansible/playbooks/deploy-app.yml
```

## Notes

- `promotion-service` and `agent-service` both default to `8093`; in `app-2`, only `promotion-service` publishes host port `8093`.
- The old `terraform/enviroments` directory is left untouched. Use `terraform/environments`.
- For production, prefer ACM + Route 53, set `certificate_arn`, restrict SSH, and move secrets to SSM Parameter Store or Secrets Manager.
