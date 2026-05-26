output "cluster_name" {
  value = var.cluster_name
}

output "kubeconfig_context" {
  value = "k3d-${var.cluster_name}"
}

output "grafana_url" {
  value = "http://localhost:${var.grafana_port}"
}

output "prometheus_url" {
  value = "http://localhost:${var.prometheus_port}"
}

output "alertmanager_url" {
  value = "http://localhost:${var.alertmanager_port}"
}
