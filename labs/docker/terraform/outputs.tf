output "app_external_urls" {
  description = "HTTP URLs for simulated application nodes from the host."
  value       = local.app_external_urls
}

output "app_prometheus_targets" {
  description = "Container-network URLs scraped through blackbox exporter."
  value       = local.app_targets
}

output "ansible_inventory_path" {
  description = "Generated Ansible inventory for Docker lab deployment."
  value       = local_file.ansible_inventory.filename
}

output "grafana_url" {
  description = "Grafana URL for the Docker lab."
  value       = "http://localhost:${var.grafana_port}"
}

output "prometheus_url" {
  description = "Prometheus URL for the Docker lab."
  value       = "http://localhost:${var.prometheus_port}"
}
