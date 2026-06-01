SHELL := /usr/bin/env bash

ENV ?= dev
TF_DIR ?= terraform
TFVARS ?= $(TF_DIR)/environments/$(ENV).tfvars
TF_OUTPUT ?= terraform-output.json
INVENTORY ?= ansible/inventory/$(ENV).ini
BACKEND_DIR ?= ../nexatech-backend
DOCKERHUB_NAMESPACE ?= trungnguyen918
DOCKER_BUILD_PARALLELISM ?= 4
IMAGE_TAG ?= $(shell git -C $(BACKEND_DIR) rev-parse --short main 2>/dev/null || echo latest)
VAULT_ARGS ?= --ask-vault-pass
ANSIBLE_TEMP_ENV := ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote-ubuntu

.DEFAULT_GOAL := help

.PHONY: help \
	tf-init tf-fmt tf-validate tf-plan tf-apply tf-output inventory provision \
	build-backend deploy-infra deploy-app deploy-all redeploy redeploy-infra redeploy-app redeploy-services \
	compose-validate ansible-syntax validate status show-vars

help:
	@printf '%s\n' 'NexaTech infra commands'
	@printf '\n%s\n' 'Common:'
	@printf '  %-22s %s\n' 'make provision' 'terraform apply, write output, render Ansible inventory'
	@printf '  %-22s %s\n' 'make build-backend' 'build and push all backend Docker images'
	@printf '  %-22s %s\n' 'make redeploy' 'redeploy infra and app with IMAGE_TAG'
	@printf '  %-22s %s\n' 'make redeploy-app' 'redeploy app hosts only'
	@printf '  %-22s %s\n' 'make redeploy-services' 'redeploy selected SERVICES on app hosts'
	@printf '\n%s\n' 'Terraform:'
	@printf '  %-22s %s\n' 'make tf-init' 'terraform init'
	@printf '  %-22s %s\n' 'make tf-plan' 'terraform plan with TFVARS'
	@printf '  %-22s %s\n' 'make tf-apply' 'terraform apply with TFVARS'
	@printf '  %-22s %s\n' 'make inventory' 'render ansible inventory from terraform output'
	@printf '\n%s\n' 'Ansible:'
	@printf '  %-22s %s\n' 'make deploy-infra' 'run deploy-infra.yml'
	@printf '  %-22s %s\n' 'make deploy-app' 'run deploy-app.yml'
	@printf '  %-22s %s\n' 'make deploy-all' 'run infra then app playbooks'
	@printf '\n%s\n' 'Validation:'
	@printf '  %-22s %s\n' 'make validate' 'terraform validate, compose config, ansible syntax'
	@printf '  %-22s %s\n' 'make compose-validate' 'validate compose files'
	@printf '  %-22s %s\n' 'make ansible-syntax' 'syntax-check playbooks'
	@printf '\n%s\n' 'Useful variables:'
	@printf '  ENV=%s TFVARS=%s INVENTORY=%s\n' '$(ENV)' '$(TFVARS)' '$(INVENTORY)'
	@printf '  IMAGE_TAG=%s DOCKERHUB_NAMESPACE=%s VAULT_ARGS=%s\n' '$(IMAGE_TAG)' '$(DOCKERHUB_NAMESPACE)' '$(VAULT_ARGS)'
	@printf '\n%s\n' 'Example: make redeploy-services SERVICES="user-service order-service" IMAGE_TAG=abc123'

show-vars:
	@printf 'ENV=%s\n' '$(ENV)'
	@printf 'TFVARS=%s\n' '$(TFVARS)'
	@printf 'TF_OUTPUT=%s\n' '$(TF_OUTPUT)'
	@printf 'INVENTORY=%s\n' '$(INVENTORY)'
	@printf 'BACKEND_DIR=%s\n' '$(BACKEND_DIR)'
	@printf 'DOCKERHUB_NAMESPACE=%s\n' '$(DOCKERHUB_NAMESPACE)'
	@printf 'IMAGE_TAG=%s\n' '$(IMAGE_TAG)'
	@printf 'VAULT_ARGS=%s\n' '$(VAULT_ARGS)'

status:
	git status --short

tf-init:
	terraform -chdir=$(TF_DIR) init

tf-fmt:
	terraform -chdir=$(TF_DIR) fmt -recursive

tf-validate: tf-init
	terraform -chdir=$(TF_DIR) validate

tf-plan: tf-init
	terraform -chdir=$(TF_DIR) plan -var-file=environments/$(ENV).tfvars

tf-apply: tf-init
	terraform -chdir=$(TF_DIR) apply -var-file=environments/$(ENV).tfvars

tf-output:
	terraform -chdir=$(TF_DIR) output -json > $(TF_OUTPUT)

inventory:
	DOCKERHUB_NAMESPACE=$(DOCKERHUB_NAMESPACE) IMAGE_TAG=$(IMAGE_TAG) ./scripts/render-inventory.sh $(TF_OUTPUT) $(INVENTORY)

provision: tf-apply tf-output inventory

build-backend:
	DOCKERHUB_USERNAME="$(DOCKERHUB_USERNAME)" DOCKERHUB_TOKEN="$(DOCKERHUB_TOKEN)" DOCKERHUB_NAMESPACE="$(DOCKERHUB_NAMESPACE)" DOCKER_BUILD_PARALLELISM="$(DOCKER_BUILD_PARALLELISM)" $(BACKEND_DIR)/_scripts/build-push-all-dockerhub.sh

deploy-infra:
	$(ANSIBLE_TEMP_ENV) ansible-playbook -i $(INVENTORY) ansible/playbooks/deploy-infra.yml --extra-vars dockerhub_namespace=$(DOCKERHUB_NAMESPACE) --extra-vars image_tag=$(IMAGE_TAG) $(VAULT_ARGS)

deploy-app:
	$(ANSIBLE_TEMP_ENV) ansible-playbook -i $(INVENTORY) ansible/playbooks/deploy-app.yml --extra-vars dockerhub_namespace=$(DOCKERHUB_NAMESPACE) --extra-vars image_tag=$(IMAGE_TAG) $(VAULT_ARGS)

deploy-all: deploy-infra deploy-app

redeploy:
	DOCKERHUB_NAMESPACE=$(DOCKERHUB_NAMESPACE) ./scripts/redeploy-images.sh $(IMAGE_TAG) --target all --inventory $(INVENTORY) --namespace $(DOCKERHUB_NAMESPACE) $(VAULT_ARGS)

redeploy-infra:
	DOCKERHUB_NAMESPACE=$(DOCKERHUB_NAMESPACE) ./scripts/redeploy-images.sh $(IMAGE_TAG) --target infra --inventory $(INVENTORY) --namespace $(DOCKERHUB_NAMESPACE) $(VAULT_ARGS)

redeploy-app:
	DOCKERHUB_NAMESPACE=$(DOCKERHUB_NAMESPACE) ./scripts/redeploy-images.sh $(IMAGE_TAG) --target app --inventory $(INVENTORY) --namespace $(DOCKERHUB_NAMESPACE) $(VAULT_ARGS)

redeploy-services:
	@test -n "$(SERVICES)" || { printf '%s\n' 'Usage: make redeploy-services SERVICES="user-service order-service" IMAGE_TAG=abc123'; exit 1; }
	DOCKERHUB_NAMESPACE=$(DOCKERHUB_NAMESPACE) ./scripts/redeploy-images.sh $(IMAGE_TAG) --target app --services "$(SERVICES)" --inventory $(INVENTORY) --namespace $(DOCKERHUB_NAMESPACE) $(VAULT_ARGS)

compose-validate:
	docker compose -f docker-compose/infra.docker-compose.yml config --quiet
	docker compose -f docker-compose/app-1.docker-compose.yml config --quiet
	docker compose -f docker-compose/app-2.docker-compose.yml config --quiet

ansible-syntax:
	$(ANSIBLE_TEMP_ENV) ansible-playbook --syntax-check -i $(INVENTORY) ansible/playbooks/deploy-infra.yml --extra-vars dockerhub_namespace=$(DOCKERHUB_NAMESPACE) --extra-vars image_tag=$(IMAGE_TAG) $(VAULT_ARGS)
	$(ANSIBLE_TEMP_ENV) ansible-playbook --syntax-check -i $(INVENTORY) ansible/playbooks/deploy-app.yml --extra-vars dockerhub_namespace=$(DOCKERHUB_NAMESPACE) --extra-vars image_tag=$(IMAGE_TAG) $(VAULT_ARGS)

validate: tf-validate compose-validate ansible-syntax
