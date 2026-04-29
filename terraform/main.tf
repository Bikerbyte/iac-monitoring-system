terraform {
  required_version = ">= 1.5.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

locals {
  selected_hosts = slice(var.vm_hosts, 0, var.node_count)

  inventory_lines = [
    for host in local.selected_hosts :
    format(
      "%s ansible_host=%s ansible_user=%s ansible_ssh_private_key_file=%s",
      host.name,
      host.ip_address,
      host.ansible_user,
      host.ssh_private_key_file
    )
  ]
}

# Local lab mode:
# Terraform owns the desired node list and generates the Ansible inventory.
# In a real VMware/cloud environment, replace this section with VM resources
# and keep the outputs/inventory shape the same for Ansible.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content  = "${join("\n", concat(["[monitoring_agents]"], local.inventory_lines))}\n"
}
