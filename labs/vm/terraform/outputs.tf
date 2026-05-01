output "lab_mode" {
  description = "Current VM lab mode."
  value       = var.enable_aws_resources ? "aws-ec2" : "mock-inventory"
}

output "vm_ip_addresses" {
  description = "Linux node IP addresses passed to Ansible."
  value       = [for host in local.selected_hosts : host.ip_address]
}

output "ansible_inventory_path" {
  description = "Generated Ansible inventory path."
  value       = local_file.ansible_inventory.filename
}

output "grafana_url" {
  description = "Grafana URL exposed by the monitoring stack host."
  value       = "http://${local.stack_host.ip_address}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL exposed by the monitoring stack host."
  value       = "http://${local.stack_host.ip_address}:9090"
}

output "aws_instance_ids" {
  description = "EC2 instance IDs created when enable_aws_resources is true."
  value       = [for instance in aws_instance.monitor_node : instance.id]
}
