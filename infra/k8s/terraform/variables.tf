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
