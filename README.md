# NexaTech Infra

AWS infrastructure and deploy automation for NexaTech backend.

<p align="left">
  <img src="https://img.shields.io/badge/Terraform-1.6+-7B42BC?logo=terraform&style=flat-square" alt="Terraform" />
  <img src="https://img.shields.io/badge/Ansible-latest-EE0000?logo=ansible&style=flat-square" alt="Ansible" />
  <img src="https://img.shields.io/badge/AWS-Infra-232F3E?logo=amazonwebservices&style=flat-square" alt="AWS" />
  <img src="https://img.shields.io/badge/Ubuntu-24.04-E9430F?logo=ubuntu&style=flat-square" alt="Ubuntu 24.04" />
</p>

## What This Provisions

- VPC with public/private subnets.
- EC2 nodes:
  - `infra-1`: Kong, discovery-server, config-server, api-gateway, Keycloak, Kafka.
  - `app-1`: core Java services.
  - `app-2`: shipping, news, audit, chat, storage, promotion, Python services.
- Optional RDS PostgreSQL.
- Optional public ALB routing to Kong on `infra-1`, with Kong forwarding API traffic to `api-gateway`.
- Optional private S3 buckets for storage/news assets.

The current dev sizing is intentionally not free-tier sized:

| Node | Instance type | Purpose |
| --- | --- | --- |
| `infra-1` | `m7i-flex.large` | Kafka, Keycloak, discovery, config, API gateway |
| `app-1` | `m7i-flex.large` | Core Java Spring Boot services |
| `app-2` | `c7i-flex.large` | Lighter app and Python services |

`instance_architecture` is `x86_64` so Terraform selects an Ubuntu 24.04 amd64 AMI that is compatible with the `m7i-flex` and `c7i-flex` families.

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

## Service Env Management

Service-specific env files are managed by Ansible from:

```text
ansible/group_vars/dev.secrets.yml
```

Recommended flow to avoid editing encrypted YAML from scratch:

```bash
cp env-templates/dev.secrets.yml.example ansible/group_vars/dev.secrets.yml
ansible-vault encrypt ansible/group_vars/dev.secrets.yml
```

That file contains shared values such as RDS, Redis, Mongo, Keycloak, frontend URL, and provider credentials. During deploy, Ansible writes only the relevant files for each host:

```text
/opt/nexatech/env/keycloak.env
/opt/nexatech/env/api-gateway.env
/opt/nexatech/env/identity-service.env
/opt/nexatech/env/user-service.env
```

Edit the file with real values, especially:

- `frontend_url` or both `client_frontend_url` and `admin_frontend_url`
- `api_public_url`
- `keycloak_public_url`
- `rds_endpoint`, `rds_username`, `rds_password`
- Redis, MongoDB, S3, mail, payment, and shipping credentials

For the current dev deployment, the public backend values come from Terraform output:

```yaml
api_public_url: "{{ cloudfront_api_url from terraform output }}"
keycloak_public_url: http://18.143.165.85:9000
```

If both storefront and admin are deployed on Vercel, keep both URLs in the vault file:

```yaml
client_frontend_url: https://your-client-project.vercel.app
admin_frontend_url: https://nexatech-frontend-admin.vercel.app
frontend_url: "{{ client_frontend_url }}"
frontend_allowed_origins: "{{ client_frontend_url }},{{ admin_frontend_url }}"
```

Then set the API gateway CORS value in `service_env_files.api-gateway` to:

```yaml
GATEWAY_CORS_ALLOWED_ORIGIN_PATTERNS: "{{ frontend_allowed_origins }}"
```

For notifications and customer-facing redirects, use the client URL:

```yaml
FRONTEND_URL: "{{ client_frontend_url }}"
```

Before committing real values, encrypt the file:

```bash
ansible-vault encrypt ansible/group_vars/dev.secrets.yml
```

Edit it later with:

```bash
ansible-vault edit ansible/group_vars/dev.secrets.yml
```

For local deploys, provide the vault password:

```bash
ansible-playbook --ask-vault-pass -i ansible/inventory/dev.ini ansible/playbooks/deploy-infra.yml
ansible-playbook --ask-vault-pass -i ansible/inventory/dev.ini ansible/playbooks/deploy-app.yml
```

For GitLab CI, set `ANSIBLE_VAULT_PASSWORD` as a masked and protected variable. The pipeline writes it to a temporary vault password file before running Ansible.

Deploy:

```bash
ansible-playbook -i ansible/inventory/dev.ini ansible/playbooks/deploy-infra.yml
ansible-playbook -i ansible/inventory/dev.ini ansible/playbooks/deploy-app.yml
```

If `dev.secrets.yml` is encrypted, use `--ask-vault-pass` locally or set `ANSIBLE_VAULT_PASSWORD` in CI. If it is still unencrypted with placeholder values, Ansible will deploy those placeholder values, so fill and encrypt it before a real deployment.

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
- `ANSIBLE_VAULT_PASSWORD` if `ansible/group_vars/dev.secrets.yml` is encrypted
- `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DOCKERHUB_NAMESPACE`

The backend project must be allowed to trigger this project with `CI_JOB_TOKEN`, or it must use an infra pipeline trigger token stored as a protected CI variable.

## Build And Deploy All Services

Common commands are also wrapped in the repo `Makefile`:

```bash
make help
make build-backend
make redeploy IMAGE_TAG=<backend-image-tag>
make redeploy-services SERVICES="user-service order-service" IMAGE_TAG=<backend-image-tag>
```

Build and push every backend image from the backend repository:

```bash
cd ../nexatech-backend
DOCKERHUB_USERNAME=<dockerhub-user> \
DOCKERHUB_TOKEN=<dockerhub-token> \
DOCKERHUB_NAMESPACE=trungnguyen918 \
DOCKER_BUILD_PARALLELISM=4 \
  _scripts/build-push-all-dockerhub.sh
```

The script tags images with `git rev-parse --short main`. Capture that tag before deploying:

```bash
BACKEND_IMAGE_TAG="$(git -C ../nexatech-backend rev-parse --short main)"
```

Deploy all infra and app services with that image tag:

```bash
cd ../nexatech-infra
DOCKERHUB_USERNAME=<dockerhub-user> \
DOCKERHUB_TOKEN=<dockerhub-token> \
DOCKERHUB_NAMESPACE=trungnguyen918 \
  scripts/redeploy-images.sh "$BACKEND_IMAGE_TAG" --target all --ask-vault-pass
```

If the Ansible inventory has not been rendered for the current Terraform output yet:

```bash
terraform -chdir=terraform output -json > terraform-output.json
DOCKERHUB_NAMESPACE=trungnguyen918 IMAGE_TAG="$BACKEND_IMAGE_TAG" \
  ./scripts/render-inventory.sh terraform-output.json ansible/inventory/dev.ini
```

To deploy only application services after images are already pushed:

```bash
DOCKERHUB_USERNAME=<dockerhub-user> \
DOCKERHUB_TOKEN=<dockerhub-token> \
DOCKERHUB_NAMESPACE=trungnguyen918 \
  scripts/redeploy-images.sh "$BACKEND_IMAGE_TAG" --target app --ask-vault-pass
```

## Runtime Services

- Kafka uses `apache/kafka:3.7.2`. It advertises `EXTERNAL://${INFRA_PRIVATE_IP}:9092` so app nodes can connect across the VPC. Do not use `localhost` for the deployed Kafka advertised listener.
- Keycloak uses `quay.io/keycloak/keycloak:26.5.2` and reads database settings from `/opt/nexatech/env/keycloak.env`. In dev AWS, this should point to the RDS PostgreSQL endpoint.
- The app nodes receive `CONFIG_SERVER_URI`, `EUREKA_URL`, and `KAFKA_BOOTSTRAP_SERVERS` through `/opt/nexatech/runtime.env`.

## Vercel Frontends

The frontend repo has two Vercel apps:

- `admin`: React/Vite admin console
- `client`: Next.js storefront

Both apps should deploy only from the `dev` branch. The frontend projects use `vercel.json` with `git.deploymentEnabled` configured as:

```json
{
  "git": {
    "deploymentEnabled": {
      "*": false,
      "dev": true
    }
  }
}
```

Set these Vercel environment variables for the admin app:

```text
VITE_BACKEND_BASE_URL=<cloudfront_api_url>
VITE_WS_BASE_URL=<cloudfront_api_url>
```

Set these Vercel environment variables for the client app:

```text
API_GATEWAY_URL=<cloudfront_api_url>
NEXT_PUBLIC_BACKEND_BASE_URL=<cloudfront_api_url>
NEXT_PUBLIC_WS_BASE_URL=<cloudfront_api_url>
NEXT_PUBLIC_FRONTEND_URL=https://your-client-project.vercel.app
```

Keep Vercel URLs and `api_public_url` in `ansible/group_vars/dev.secrets.yml` aligned. After changing frontend URLs, rerun `deploy-infra.yml` so API Gateway gets the updated CORS origins.

## Notes

- `promotion-service` and `agent-service` both default to `8093`; in `app-2`, only `promotion-service` publishes host port `8093`.
- The old `terraform/enviroments` directory is left untouched. Use `terraform/environments`.
- If SSH to an app node fails, check that `key_name` matches an existing EC2 key pair, `allowed_ssh_cidrs` includes your current public IP, the instance was recreated after key/security-group changes, and you are using the `ubuntu` user.
- For production, prefer ACM + Route 53, set `certificate_arn`, restrict SSH, and move secrets to SSM Parameter Store or Secrets Manager.
