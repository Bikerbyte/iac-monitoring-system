variable "cluster_name" {
  description = "k3d cluster name."
  type        = string
  default     = "iac-monitoring"
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file. k3d writes the cluster context here automatically."
  type        = string
  default     = "~/.kube/config"
}

variable "chart_version" {
  description = "kube-prometheus-stack Helm chart version."
  type        = string
  default     = "65.0.0"
}

variable "agent_image" {
  description = "Local Docker image tag for monitor-agent; must exist on the host before apply (built via `make build-agent-image`)."
  type        = string
  default     = "monitor-agent:dev"
}

variable "grafana_port" {
  description = "Host port mapped to Grafana through the k3d load balancer."
  type        = number
  default     = 3000
}

variable "prometheus_port" {
  description = "Host port mapped to Prometheus through the k3d load balancer."
  type        = number
  default     = 9090
}

variable "alertmanager_port" {
  description = "Host port mapped to Alertmanager through the k3d load balancer."
  type        = number
  default     = 9093
}
