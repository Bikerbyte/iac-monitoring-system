SHELL := /usr/bin/env bash

DOCKER_TF_DIR := infra/docker/terraform
SERVER_TF_DIR := infra/server/terraform
NODE_COUNT ?= 3
ANSIBLE_FLAGS ?=

.PHONY: help validate prepare-validation-files docker-init docker-up docker-ansible docker-scale docker-edit docker-down server-init server-plan server-apply server-agent server-stack server-up

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
	@echo "  make server-stack              Deploy Prometheus/Grafana on this control node"
	@echo "  make server-up                 Deploy remote agents and local stack"

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

prepare-validation-files:
	mkdir -p ansible/group_vars/monitoring_stack
	test -f ansible/inventory.ini || printf '[monitoring_agents]\nmonitor-node-02 ansible_host=127.0.0.1 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa\n\n[monitoring_stack]\nlocalhost ansible_connection=local\n' > ansible/inventory.ini

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

server-stack:
	ansible-playbook -i ansible/inventory.ini ansible/server-agent.yml --limit monitoring_stack $(ANSIBLE_FLAGS)

server-up:
	$(MAKE) server-agent
	$(MAKE) server-stack
