SHELL := /usr/bin/env bash

DOCKER_TF_DIR := labs/docker/terraform
VM_TF_DIR := labs/vm/terraform
NODE_COUNT ?= 3

.PHONY: help validate prepare-validation-files docker-init docker-up docker-ansible docker-scale docker-edit docker-down vm-init vm-plan vm-apply

help:
	@echo "Targets:"
	@echo "  make validate                  Run Terraform, Ansible, JSON, and Python checks"
	@echo "  make docker-up                 Apply Docker lab Terraform and deploy monitoring stack"
	@echo "  make docker-scale NODE_COUNT=3 Scale Docker app nodes and redeploy Prometheus/Grafana"
	@echo "  make docker-edit               Change app response text and redeploy monitoring stack"
	@echo "  make docker-down               Destroy Docker lab resources and monitoring containers"
	@echo "  make vm-plan                   Plan VM lab in safe mock mode"
	@echo "  make vm-apply                  Apply VM lab in safe mock mode"

validate: prepare-validation-files
	terraform -chdir=$(DOCKER_TF_DIR) fmt -check
	terraform -chdir=$(DOCKER_TF_DIR) init -backend=false
	terraform -chdir=$(DOCKER_TF_DIR) validate
	terraform -chdir=$(VM_TF_DIR) fmt -check
	terraform -chdir=$(VM_TF_DIR) init -backend=false
	terraform -chdir=$(VM_TF_DIR) validate
	ansible-playbook --syntax-check -i ansible/docker-lab-inventory.ini ansible/docker-lab.yml
	ansible-playbook --syntax-check -i ansible/inventory.ini ansible/playbook.yml
	jq empty ansible/files/docker-lab/grafana/dashboards/*.json ansible/files/grafana/dashboards/*.json
	python3 -m py_compile agent/agent.py

prepare-validation-files:
	mkdir -p ansible/group_vars/docker_lab_stack
	test -f ansible/docker-lab-inventory.ini || printf '[docker_lab_stack]\nlocalhost ansible_connection=local\n' > ansible/docker-lab-inventory.ini
	test -f ansible/inventory.ini || printf '[monitoring_agents]\nmonitor-node-01 ansible_host=127.0.0.1 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa\n\n[monitoring_stack]\nmonitor-node-01\n' > ansible/inventory.ini
	test -f ansible/group_vars/docker_lab_stack/generated.yml || printf 'iac_docker_lab_network: iac-docker-lab\niac_docker_lab_app_targets:\n  - http://iac-lab-app-node-01:5678\niac_docker_lab_grafana_port: 13000\niac_docker_lab_prometheus_port: 19090\niac_docker_lab_blackbox_port: 19115\n' > ansible/group_vars/docker_lab_stack/generated.yml

docker-init:
	terraform -chdir=$(DOCKER_TF_DIR) init

docker-up: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply
	$(MAKE) docker-ansible

docker-ansible:
	ansible-playbook -i ansible/docker-lab-inventory.ini ansible/docker-lab.yml

docker-scale: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply -var="node_count=$(NODE_COUNT)"
	$(MAKE) docker-ansible

docker-edit: docker-init
	terraform -chdir=$(DOCKER_TF_DIR) apply -var="app_message_prefix=updated by terraform"
	$(MAKE) docker-ansible

docker-down:
	terraform -chdir=$(DOCKER_TF_DIR) destroy
	docker rm -f iac-lab-blackbox iac-lab-prometheus iac-lab-grafana >/dev/null 2>&1 || true

vm-init:
	terraform -chdir=$(VM_TF_DIR) init

vm-plan: vm-init
	terraform -chdir=$(VM_TF_DIR) plan

vm-apply: vm-init
	terraform -chdir=$(VM_TF_DIR) apply
