SHELL := /usr/bin/env bash

DOCKER_TF_DIR := infra/docker/terraform
SERVER_TF_DIR := infra/server/terraform
NODE_COUNT ?= 3
ANSIBLE_FLAGS ?=

.PHONY: help validate prepare-validation-files docker-init docker-up docker-ansible docker-scale docker-edit docker-down server-init server-plan server-apply server-agent server-stack server-up

help:
	@echo "Targets:"
	@echo "  make validate                  Run Terraform, Ansible, JSON, and Python checks"
	@echo "  make docker-up                 Apply Docker target mode Terraform and deploy monitoring stack"
	@echo "  make docker-scale NODE_COUNT=3 Scale Docker app nodes and redeploy Prometheus/Grafana"
	@echo "  make docker-edit               Change app response text and redeploy monitoring stack"
	@echo "  make docker-down               Destroy Docker target mode resources and monitoring containers"
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
	ansible-playbook --syntax-check -i ansible/docker-target-inventory.ini ansible/docker-target.yml
	ansible-playbook --syntax-check -i ansible/inventory.ini ansible/server-agent.yml
	jq empty ansible/files/docker-target/grafana/dashboards/*.json ansible/files/grafana/dashboards/*.json
	python3 -m py_compile agent/agent.py

prepare-validation-files:
	mkdir -p ansible/group_vars/docker_target_stack
	test -f ansible/docker-target-inventory.ini || printf '[docker_target_stack]\nlocalhost ansible_connection=local\n' > ansible/docker-target-inventory.ini
	test -f ansible/inventory.ini || printf '[monitoring_agents]\nmonitor-node-02 ansible_host=127.0.0.1 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa\n\n[monitoring_stack]\nlocalhost ansible_connection=local\n' > ansible/inventory.ini
	test -f ansible/group_vars/docker_target_stack/generated.yml || printf 'iac_docker_target_network: iac-docker-lab\niac_docker_target_app_targets:\n  - http://iac-lab-app-node-01:5678\niac_docker_target_grafana_port: 13000\niac_docker_target_prometheus_port: 19090\niac_docker_target_blackbox_port: 19115\n' > ansible/group_vars/docker_target_stack/generated.yml

docker-init:
	terraform -chdir=$(DOCKER_TF_DIR) init

docker-up: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply
	$(MAKE) docker-ansible

docker-ansible:
	ansible-playbook -i ansible/docker-target-inventory.ini ansible/docker-target.yml

docker-scale: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply -var="node_count=$(NODE_COUNT)"
	$(MAKE) docker-ansible

docker-edit: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply -var="app_message_prefix=updated by terraform"
	$(MAKE) docker-ansible

docker-down:
	terraform -chdir=$(DOCKER_TF_DIR) destroy
	docker rm -f iac-lab-blackbox iac-lab-prometheus iac-lab-grafana >/dev/null 2>&1 || true

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
