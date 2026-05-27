# NexaTech Infra

Low-cost AWS infrastructure for NexaTech backend.

## What This Provisions

- VPC with public/private subnets.
- EC2 nodes:
  - `infra-1`: discovery-server, config-server, api-gateway, Keycloak, Kafka.
  - `app-1`: core Java services.
  - optional `app-2`: shipping, news, audit, chat, storage, promotion, Python services.
- Optional RDS PostgreSQL.
- Optional public ALB routing to `api-gateway`.
- Optional private S3 buckets for storage/news assets.

## Prerequisites

- Terraform >= 1.6
- Ansible
- AWS credentials with permissions for EC2, VPC, IAM, RDS, ALB, and S3
- `jq` for `scripts/render-inventory.sh`
- `pre-commit` if you want local Git hooks

## Local Hooks

Install local validation tools:

```bash
pip install pre-commit ansible-lint checkov
npm install -g gitlab-ci-local
```

Install Terraform tools separately:

```bash
# macOS example
brew install terraform tflint tfsec
```

Install the pre-push hook:

```bash
pre-commit install --hook-type pre-push
```

Before every push, the hook runs:

- `terraform fmt -check -recursive`
- `terraform init -backend=false -input=false`
- `terraform validate`
- `terraform plan -var-file=environments/dev.tfvars -out=plan.tfplan`
- `terraform show -no-color plan.tfplan`
- `tflint --chdir=terraform`
- `tfsec terraform`
- `checkov -d terraform --quiet`
- `ansible-lint ansible`
- `gitlab-ci-local --list`

Run all pre-push checks manually:

```bash
pre-commit run --hook-stage pre-push --all-files
```

If a heavy check is not needed for an urgent push, skip it explicitly:

```bash
SKIP=terraform-plan-show,tfsec,checkov git push
```

For larger Ansible changes, add Molecule scenarios under each role before wiring Molecule into the hook. For a larger multi-environment Terraform layout, consider Terragrunt or OpenTofu/Terraform Cloud with remote state locking.

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

Set `dockerhub_namespace` and `image_tag` in `ansible/inventory/dev.ini`.

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
