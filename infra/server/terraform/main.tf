terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  access_key                  = var.enable_aws_resources ? null : "mock-access-key"
  secret_key                  = var.enable_aws_resources ? null : "mock-secret-key"
  skip_credentials_validation = !var.enable_aws_resources
  skip_metadata_api_check     = !var.enable_aws_resources
  skip_region_validation      = !var.enable_aws_resources
  skip_requesting_account_id  = !var.enable_aws_resources
}

locals {
  aws_hosts = [
    for index, instance in aws_instance.monitor_node :
    {
      name                 = instance.tags.Name
      ip_address           = instance.public_ip
      ansible_user         = var.ansible_user
      ssh_private_key_file = var.ssh_private_key_file
    }
  ]

  existing_hosts = slice(var.server_hosts, 0, var.node_count)
  selected_hosts = var.enable_aws_resources ? local.aws_hosts : local.existing_hosts

  inventory_lines = [
    for host in local.selected_hosts :
    trimspace(join(" ", compact([
      host.name,
      "ansible_host=${host.ip_address}",
      "ansible_user=${host.ansible_user}",
      host.ssh_private_key_file != "" ? "ansible_ssh_private_key_file=${host.ssh_private_key_file}" : "",
    ])))
  ]
}

resource "aws_key_pair" "lab" {
  count = var.enable_aws_resources ? 1 : 0

  key_name   = var.aws_key_pair_name
  public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "aws_security_group" "monitoring_lab" {
  count = var.enable_aws_resources ? 1 : 0

  name        = var.aws_security_group_name
  description = "Allow SSH and monitoring system ports"
  vpc_id      = var.aws_vpc_id

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr_blocks
  }

  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.allowed_monitoring_cidr_blocks
  }

  ingress {
    description = "Alertmanager"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = var.allowed_monitoring_cidr_blocks
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.allowed_monitoring_cidr_blocks
  }

  ingress {
    description = "Node Exporter metrics"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = var.allowed_monitoring_cidr_blocks
  }

  ingress {
    description = "monitor-agent Prometheus metrics"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = var.allowed_monitoring_cidr_blocks
  }

  egress {
    description = "Outbound internet access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = var.aws_security_group_name
    Project = "iac-monitoring-system"
  }
}

resource "aws_instance" "monitor_node" {
  count = var.enable_aws_resources ? var.node_count : 0

  ami                         = var.aws_ami_id
  instance_type               = var.aws_instance_type
  subnet_id                   = var.aws_subnet_id
  key_name                    = aws_key_pair.lab[0].key_name
  vpc_security_group_ids      = [aws_security_group.monitoring_lab[0].id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.aws_root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = format("%s-%02d", var.aws_instance_name_prefix, count.index + 1)
    Project = "iac-monitoring-system"
  }
}

# Terraform owns the desired node list and generates the Ansible inventory.
# By default this system runs in safe mock mode. Set enable_aws_resources=true
# when you are ready to create real EC2 instances.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../../../ansible/inventory.ini"
  content = format("%s\n", join("\n", concat(
    ["[monitoring_agents]"],
    local.inventory_lines,
    ["", "[monitoring_stack]", "localhost ansible_connection=local"],
  )))
}
