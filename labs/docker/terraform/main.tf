terraform {
  required_version = ">= 1.5.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "docker" {}

locals {
  app_targets = [
    for container in docker_container.app_node :
    "http://${container.name}:5678"
  ]

  app_external_urls = [
    for index in range(var.node_count) :
    "http://localhost:${var.host_http_base_port + index}"
  ]
}

resource "docker_network" "lab" {
  name = var.lab_network_name
}

resource "docker_image" "app" {
  name         = var.app_image
  keep_locally = true
}

resource "docker_container" "app_node" {
  count = var.node_count

  name    = format("%s-%02d", var.app_container_prefix, count.index + 1)
  image   = docker_image.app.image_id
  restart = "unless-stopped"
  command = [
    "-listen=:5678",
    "-text=${var.app_message_prefix} ${count.index + 1}",
  ]

  networks_advanced {
    name = docker_network.lab.name
  }

  ports {
    internal = 5678
    external = var.host_http_base_port + count.index
  }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../../../ansible/docker-lab-inventory.ini"
  content  = <<-EOT
    [docker_lab_stack]
    localhost ansible_connection=local
  EOT
}

resource "local_file" "ansible_group_vars" {
  filename = "${path.module}/../../../ansible/group_vars/docker_lab_stack/generated.yml"
  content = yamlencode({
    iac_docker_lab_network         = docker_network.lab.name
    iac_docker_lab_app_targets     = local.app_targets
    iac_docker_lab_grafana_port    = var.grafana_port
    iac_docker_lab_prometheus_port = var.prometheus_port
    iac_docker_lab_blackbox_port   = var.blackbox_port
  })
}
