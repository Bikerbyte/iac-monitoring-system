output "system_mode" {
  description = "Current Server Agent Mode."
  value       = var.enable_aws_resources ? "aws-ec2" : "mock-inventory"
}

output "server_ip_addresses" {
  description = "Linux server IP addresses passed to Ansible."
  value       = [for host in local.selected_hosts : host.ip_address]
}

output "server_hosts" {
  description = "Linux server SSH connection info passed to Ansible."
  value = [
    for host in local.selected_hosts : {
      name                 = host.name
      ip_address           = host.ip_address
      ansible_user         = host.ansible_user
      ssh_private_key_file = host.ssh_private_key_file
    }
  ]
}

output "monitor_agent_targets" {
  description = "Prometheus targets for the Python monitoring agent."
  value       = [for host in local.selected_hosts : "${host.ip_address}:8000"]
}

output "node_exporter_targets" {
  description = "Prometheus targets for Node Exporter Linux host metrics."
  value       = [for host in local.selected_hosts : "${host.ip_address}:9100"]
}

output "ansible_inventory_path" {
  description = "Generated Ansible inventory path."
  value       = local_file.ansible_inventory.filename
}

output "grafana_url" {
  description = "Grafana URL exposed by the local control node."
  value       = "http://localhost:3000"
}

output "prometheus_url" {
  description = "Prometheus URL exposed by the local control node."
  value       = "http://localhost:9090"
}

output "alertmanager_url" {
  description = "Alertmanager URL exposed by the local control node."
  value       = "http://localhost:9093"
}

output "aws_instance_ids" {
  description = "EC2 instance IDs created when enable_aws_resources is true."
  value       = [for instance in aws_instance.monitor_node : instance.id]
}
