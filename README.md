# NexaTech Infra

AWS infrastructure and deploy automation for NexaTech backend.

## What This Provisions

- VPC with public/private subnets.
- EC2 nodes:
  - `infra-1`: discovery-server, config-server, api-gateway, Keycloak, Kafka.
  - `app-1`: core Java services.
  - `app-2`: shipping, news, audit, chat, storage, promotion, Python services.
- Optional RDS PostgreSQL.
- Optional public ALB routing to `api-gateway`.
- Optional private S3 buckets for storage/news assets.

The current dev sizing is intentionally not free-tier sized:

| Node | Instance type | Purpose |
| --- | --- | --- |
| `infra-1` | `m7i-flex.xlarge` | Kafka, Keycloak, discovery, config, API gateway |
| `app-1` | `m7i-flex.xlarge` | Core Java Spring Boot services |
| `app-2` | `m7i-flex.large` | Lighter app and Python services |

`instance_architecture` is `x86_64` so Terraform selects an Ubuntu 24.04 amd64 AMI that is compatible with the `m7i-flex` family.

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
- keep `instance_architecture = "x86_64"` for `m7i-flex.*` or `c7i-flex.*`; use `arm64` only for Graviton families such as `t4g.*`

Then run:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -var-file=environments/dev.tfvars
terraform -chdir=terraform apply -var-file=environments/dev.tfvars
terraform -chdir=terraform output -json > terraform-output.json
./scripts/render-inventory.sh terraform-output.json ansible/inventory/dev.ini
```

`scripts/render-inventory.sh` writes `dockerhub_namespace` and `image_tag` into `ansible/inventory/dev.ini`. For a manual deploy, set them explicitly:

```bash
DOCKERHUB_NAMESPACE=trungnguyen918 IMAGE_TAG=<backend-image-tag> \
  ./scripts/render-inventory.sh terraform-output.json ansible/inventory/dev.ini
```

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

## CI/CD

The backend repository builds and pushes one Docker image per service using the backend commit short SHA as the tag:

```text
DOCKERHUB_NAMESPACE/<service>:<backend-short-sha>
```

After image build, backend CI triggers this infra pipeline and passes the backend image tag through GitLab pipeline inputs:

- `backend_image_tag`
- `image_tag`

This repo resolves the deploy tag in CI as:

```bash
DEPLOY_IMAGE_TAG="${PIPELINE_BACKEND_IMAGE_TAG:-${PIPELINE_IMAGE_TAG:-latest}}"
```

The same tag is used when rendering the Ansible inventory and when running `ansible:deploy:infra` and `ansible:deploy:app`. This avoids accidentally deploying images tagged with the infra repository commit SHA.

Required GitLab CI/CD variables:

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optionally `AWS_REGION`
- `ANSIBLE_SSH_PRIVATE_KEY_B64`
- `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DOCKERHUB_NAMESPACE`

The backend project must be allowed to trigger this project with `CI_JOB_TOKEN`, or it must use an infra pipeline trigger token stored as a protected CI variable.

## Runtime Services

- Kafka uses `apache/kafka:3.7.2`. It advertises `EXTERNAL://${INFRA_PRIVATE_IP}:9092` so app nodes can connect across the VPC. Do not use `localhost` for the deployed Kafka advertised listener.
- Keycloak uses `quay.io/keycloak/keycloak:26.5.2` and reads database settings from `/opt/nexatech/env/keycloak.env`. In dev AWS, this should point to the RDS PostgreSQL endpoint.
- The app nodes receive `CONFIG_SERVER_URI`, `EUREKA_URL`, and `KAFKA_BOOTSTRAP_SERVERS` through `/opt/nexatech/runtime.env`.

## Notes

- `promotion-service` and `agent-service` both default to `8093`; in `app-2`, only `promotion-service` publishes host port `8093`.
- The old `terraform/enviroments` directory is left untouched. Use `terraform/environments`.
- If SSH to an app node fails, check that `key_name` matches an existing EC2 key pair, `allowed_ssh_cidrs` includes your current public IP, the instance was recreated after key/security-group changes, and you are using the `ubuntu` user.
- For production, prefer ACM + Route 53, set `certificate_arn`, restrict SSH, and move secrets to SSM Parameter Store or Secrets Manager.
