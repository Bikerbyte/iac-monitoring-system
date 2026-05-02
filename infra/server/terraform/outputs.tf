output "system_mode" {
  description = "Current Server Agent Mode."
  value       = var.enable_aws_resources ? "aws-ec2" : "mock-inventory"
}

output "server_ip_addresses" {
  description = "Linux server IP addresses passed to Ansible."
  value       = [for host in local.selected_hosts : host.ip_address]
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

output "aws_instance_ids" {
  description = "EC2 instance IDs created when enable_aws_resources is true."
  value       = [for instance in aws_instance.monitor_node : instance.id]
}
