SHELL := /usr/bin/env bash

VM_TF_DIR     := infra/vm/terraform
K8S_TF_DIR    := infra/k8s/terraform
K8S_DIR       := k8s
ANSIBLE_FLAGS ?=
AWS_TFVARS    ?= terraform.tfvars.aws
AGENT_IMAGE   ?= monitor-agent:dev
K3D_CLUSTER   ?= iac-monitoring

.PHONY: help validate prepare-validation-files require-aws-tfvars \
        vm-init vm-plan vm-apply vm-agent vm-stack vm-up \
        vm-aws-plan vm-aws-apply vm-aws-deploy vm-aws-destroy \
        k8s-init k8s-up k8s-down k8s-verify build-agent-image \
        vm-smoke vm-quickcheck test

help:
	@echo "VM (hybrid target) targets:"
	@echo "  make vm-plan                   Plan VM Terraform (existing Linux server inventory)"
	@echo "  make vm-apply                  Generate Ansible inventory from terraform.tfvars"
	@echo "  make vm-up                     Deploy agent + monitoring stack to inventory"
	@echo "  make vm-aws-apply              Create AWS EC2 + security group + inventory"
	@echo "  make vm-aws-deploy             Deploy agent + monitoring stack to AWS hosts"
	@echo "  make vm-aws-destroy            Destroy AWS resources"
	@echo
	@echo "Kubernetes targets:"
	@echo "  make build-agent-image         Build monitor-agent Docker image ($(AGENT_IMAGE))"
	@echo "  make k8s-up                    Terraform apply: k3d + kube-prometheus-stack + monitor-agent manifests"
	@echo "  make k8s-down                  Terraform destroy: tears down the k3d cluster and Helm release"
	@echo "  make k8s-verify                Smoke-check k8s monitoring stack"
	@echo
	@echo "Misc:"
	@echo "  make validate                  Run Terraform / Ansible / JSON / Python static checks + agent unit tests"
	@echo "  make test                      Run agent pytest suite only"
	@echo "  make vm-quickcheck             HTTP-only sanity check of VM Prometheus / Grafana / Alertmanager"
	@echo "  make vm-smoke                  Deep VM smoke check (SSH + systemctl + log + Prometheus API)"

validate: prepare-validation-files
	terraform -chdir=$(VM_TF_DIR) fmt -check
	terraform -chdir=$(VM_TF_DIR) init -backend=false
	terraform -chdir=$(VM_TF_DIR) validate
	terraform -chdir=$(K8S_TF_DIR) fmt -check
	terraform -chdir=$(K8S_TF_DIR) init -backend=false
	terraform -chdir=$(K8S_TF_DIR) validate
	ansible-playbook --syntax-check -i ansible/inventory.ini ansible/vm-deploy.yml
	jq empty ansible/files/grafana/dashboards/*.json
	python3 -m py_compile agent/agent.py
	bash -n scripts/vm-smoke.sh
	bash -n scripts/vm-quickcheck.sh
	bash -n scripts/k8s-verify.sh
	$(MAKE) test

test:
	cd agent && python3 -m pytest -q

prepare-validation-files:
	mkdir -p ansible/group_vars/monitoring_stack
	test -f ansible/inventory.ini || printf '[monitoring_agents]\nmonitor-node-02 ansible_host=127.0.0.1 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa\n\n[monitoring_stack]\nlocalhost ansible_connection=local\n' > ansible/inventory.ini

require-aws-tfvars:
	@test -f "$(VM_TF_DIR)/$(AWS_TFVARS)" || ( \
		echo "Missing $(VM_TF_DIR)/$(AWS_TFVARS)."; \
		echo "Create it with:"; \
		echo "  cp $(VM_TF_DIR)/terraform.tfvars.aws.example $(VM_TF_DIR)/$(AWS_TFVARS)"; \
		echo "Then edit AMI/VPC/subnet/CIDR values before applying."; \
		exit 1; \
	)

# ---------------- VM mode ----------------

vm-init:
	terraform -chdir=$(VM_TF_DIR) init

vm-plan: vm-init
	terraform -chdir=$(VM_TF_DIR) plan

vm-apply: vm-init
	terraform -chdir=$(VM_TF_DIR) apply

vm-agent:
	ansible-playbook -i ansible/inventory.ini ansible/vm-deploy.yml --limit monitoring_agents $(ANSIBLE_FLAGS)

vm-stack:
	ansible-playbook -i ansible/inventory.ini ansible/vm-deploy.yml --limit monitoring_stack $(ANSIBLE_FLAGS)

vm-up: vm-agent vm-stack

vm-aws-plan: require-aws-tfvars vm-init
	terraform -chdir=$(VM_TF_DIR) plan -var-file=$(AWS_TFVARS)

vm-aws-apply: require-aws-tfvars vm-init
	terraform -chdir=$(VM_TF_DIR) apply -var-file=$(AWS_TFVARS)

vm-aws-destroy: require-aws-tfvars vm-init
	terraform -chdir=$(VM_TF_DIR) destroy -var-file=$(AWS_TFVARS)

vm-aws-deploy: vm-agent vm-stack

# ---------------- k8s mode ----------------

build-agent-image:
	docker build -t $(AGENT_IMAGE) -f agent/Dockerfile .

k8s-init:
	terraform -chdir=$(K8S_TF_DIR) init

k8s-up: build-agent-image k8s-init
	terraform -chdir=$(K8S_TF_DIR) apply -auto-approve \
		-var cluster_name=$(K3D_CLUSTER) \
		-var agent_image=$(AGENT_IMAGE)

k8s-down: k8s-init
	terraform -chdir=$(K8S_TF_DIR) destroy -auto-approve \
		-var cluster_name=$(K3D_CLUSTER) \
		-var agent_image=$(AGENT_IMAGE)

k8s-verify:
	bash scripts/k8s-verify.sh

# ---------------- misc ----------------

# Deep smoke check — requires SSH into inventory hosts.
vm-smoke:
	bash scripts/vm-smoke.sh

# HTTP-only sanity check — no SSH required.
vm-quickcheck:
	bash scripts/vm-quickcheck.sh
