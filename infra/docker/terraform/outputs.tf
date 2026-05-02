output "app_external_urls" {
  description = "HTTP URLs for simulated application nodes from the host."
  value       = local.app_external_urls
}

output "app_prometheus_targets" {
  description = "Container-network URLs scraped through blackbox exporter."
  value       = local.app_targets
}

output "monitoring_stack_vars_path" {
  description = "Generated Ansible vars consumed by the central monitoring stack."
  value       = local_file.monitoring_stack_docker_targets.filename
}

output "grafana_url" {
  description = "Central Grafana URL for Docker target dashboards."
  value       = "http://localhost:3000"
}

output "prometheus_url" {
  description = "Central Prometheus URL for Docker target metrics."
  value       = "http://localhost:9090"
}
