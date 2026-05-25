output "cluster_name" {
  value = var.cluster_name
}

output "kubeconfig_context" {
  value = "k3d-${var.cluster_name}"
}

output "grafana_url" {
  value = "http://localhost:3000"
}

output "prometheus_url" {
  value = "http://localhost:9090"
}
