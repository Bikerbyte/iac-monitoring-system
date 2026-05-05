SHELL := /usr/bin/env bash

DOCKER_TF_DIR := infra/docker/terraform
SERVER_TF_DIR := infra/server/terraform
NODE_COUNT ?= 3
ANSIBLE_FLAGS ?=
AWS_TFVARS ?= terraform.tfvars.aws

.PHONY: help validate prepare-validation-files require-aws-tfvars docker-init docker-up docker-ansible docker-scale docker-edit docker-down server-init server-plan server-apply server-agent server-agent-aws server-stack server-up server-aws-plan server-aws-apply server-aws-destroy server-aws-deploy smoke-server smoke-aws

help:
	@echo "Targets:"
	@echo "  make validate                  Run Terraform, Ansible, JSON, and Python checks"
	@echo "  make docker-up                 Apply Docker target mode Terraform and update central stack"
	@echo "  make docker-scale NODE_COUNT=3 Scale Docker app nodes and update central stack"
	@echo "  make docker-edit               Change app response text and update central stack"
	@echo '  make docker-down ANSIBLE_FLAGS="--ask-become-pass" Destroy Docker target mode resources and update central stack'
	@echo "  make server-plan               Plan Server Agent Mode"
	@echo "  make server-apply              Apply Server Agent Mode inventory"
	@echo "  make server-agent              Deploy Python agent to remote servers"
	@echo "  make server-agent-aws          Deploy Python agent with AWS-safe network checks"
	@echo "  make server-stack              Deploy Prometheus/Grafana on this control node"
	@echo "  make server-up                 Deploy remote agents and local stack"
	@echo "  make server-aws-plan           Plan AWS EC2 Server Agent Mode with infra/server/terraform/$(AWS_TFVARS)"
	@echo "  make server-aws-apply          Create AWS EC2 resources and generate Ansible inventory"
	@echo "  make server-aws-deploy         Deploy AWS-safe agent config and local monitoring stack"
	@echo "  make smoke-server              Run end-to-end health checks"
	@echo "  make server-aws-destroy        Destroy AWS EC2 resources managed by Terraform"

validate: prepare-validation-files
	terraform -chdir=$(DOCKER_TF_DIR) fmt -check
	terraform -chdir=$(DOCKER_TF_DIR) init -backend=false
	terraform -chdir=$(DOCKER_TF_DIR) validate
	terraform -chdir=$(SERVER_TF_DIR) fmt -check
	terraform -chdir=$(SERVER_TF_DIR) init -backend=false
	terraform -chdir=$(SERVER_TF_DIR) validate
	ansible-playbook --syntax-check -i ansible/inventory.ini ansible/server-agent.yml
	jq empty ansible/files/docker-target/grafana/dashboards/*.json ansible/files/grafana/dashboards/*.json
	python3 -m py_compile agent/agent.py
	bash -n scripts/smoke-server.sh

prepare-validation-files:
	mkdir -p ansible/group_vars/monitoring_stack
	test -f ansible/inventory.ini || printf '[monitoring_agents]\nmonitor-node-02 ansible_host=127.0.0.1 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa\n\n[monitoring_stack]\nlocalhost ansible_connection=local\n' > ansible/inventory.ini

require-aws-tfvars:
	@test -f "$(SERVER_TF_DIR)/$(AWS_TFVARS)" || ( \
		echo "Missing $(SERVER_TF_DIR)/$(AWS_TFVARS)."; \
		echo "Create it with:"; \
		echo "  cp $(SERVER_TF_DIR)/terraform.tfvars.aws.example $(SERVER_TF_DIR)/$(AWS_TFVARS)"; \
		echo "Then edit AMI/VPC/subnet/CIDR values before applying."; \
		exit 1; \
	)

docker-init:
	terraform -chdir=$(DOCKER_TF_DIR) init

docker-up: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply
	$(MAKE) server-stack

docker-ansible:
	$(MAKE) server-stack

docker-scale: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply -var="node_count=$(NODE_COUNT)"
	$(MAKE) server-stack

docker-edit: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply -var="app_message_prefix=updated by terraform"
	$(MAKE) server-stack

docker-down:
	terraform -chdir=$(DOCKER_TF_DIR) destroy
	rm -f ansible/group_vars/monitoring_stack/docker_targets.yml
	docker rm -f blackbox iac-lab-blackbox iac-lab-prometheus iac-lab-grafana >/dev/null 2>&1 || true
	$(MAKE) server-stack

server-init:
	terraform -chdir=$(SERVER_TF_DIR) init

server-plan: server-init
	terraform -chdir=$(SERVER_TF_DIR) plan

server-apply: server-init
	terraform -chdir=$(SERVER_TF_DIR) apply

server-agent:
	ansible-playbook -i ansible/inventory.ini ansible/server-agent.yml --limit monitoring_agents $(ANSIBLE_FLAGS)

server-agent-aws:
	ansible-playbook -i ansible/inventory.ini ansible/server-agent.yml --limit monitoring_agents -e agent_config_src=../agent/config.aws.yml $(ANSIBLE_FLAGS)

server-stack:
	ansible-playbook -i ansible/inventory.ini ansible/server-agent.yml --limit monitoring_stack $(ANSIBLE_FLAGS)

server-up:
	$(MAKE) server-agent
	$(MAKE) server-stack

server-aws-plan: require-aws-tfvars server-init
	terraform -chdir=$(SERVER_TF_DIR) plan -var-file=$(AWS_TFVARS)

server-aws-apply: require-aws-tfvars server-init
	terraform -chdir=$(SERVER_TF_DIR) apply -var-file=$(AWS_TFVARS)

server-aws-destroy: require-aws-tfvars server-init
	terraform -chdir=$(SERVER_TF_DIR) destroy -var-file=$(AWS_TFVARS)

server-aws-deploy:
	$(MAKE) server-agent-aws
	$(MAKE) server-stack

smoke-server:
	bash scripts/smoke-server.sh

smoke-aws: smoke-server
