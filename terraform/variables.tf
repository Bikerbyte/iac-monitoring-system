variable "node_count" {
  description = "Number of Linux nodes to manage in this lab. Keep this between 1 and 2 for the learning scenario."
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 2
    error_message = "node_count must be 1 or 2."
  }
}

variable "network_cidr" {
  description = "Expected lab network CIDR. Kept here so the network setting is explicit in Terraform."
  type        = string
  default     = "192.168.1.0/24"
}

variable "vm_hosts" {
  description = "Linux hosts that Terraform will expose to Ansible. Replace the IPs with your VM addresses."
  type = list(object({
    name                 = string
    ip_address           = string
    ansible_user         = string
    ssh_private_key_file = string
  }))

  default = [
    {
      name                 = "monitor-node-01"
      ip_address           = "192.168.1.101"
      ansible_user         = "ubuntu"
      ssh_private_key_file = "~/.ssh/id_rsa"
    },
    {
      name                 = "monitor-node-02"
      ip_address           = "192.168.1.102"
      ansible_user         = "ubuntu"
      ssh_private_key_file = "~/.ssh/id_rsa"
    }
  ]
}
