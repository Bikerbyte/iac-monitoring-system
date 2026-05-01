variable "node_count" {
  description = "Number of simulated application nodes to create as Docker containers."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 5
    error_message = "node_count must be between 1 and 5."
  }
}

variable "lab_network_name" {
  description = "Docker network used by the simulated lab resources and monitoring stack."
  type        = string
  default     = "iac-docker-lab"
}

variable "app_image" {
  description = "HTTP echo image used to simulate application nodes."
  type        = string
  default     = "hashicorp/http-echo:1.0"
}

variable "app_container_prefix" {
  description = "Name prefix for simulated application containers."
  type        = string
  default     = "iac-lab-app-node"
}

variable "app_message_prefix" {
  description = "Text returned by each simulated app node. Change this to simulate editing a resource."
  type        = string
  default     = "hello from terraform node"
}

variable "host_http_base_port" {
  description = "First host port mapped to simulated app nodes."
  type        = number
  default     = 18080
}

variable "grafana_port" {
  description = "Host port for the Docker lab Grafana container."
  type        = number
  default     = 13000
}

variable "prometheus_port" {
  description = "Host port for the Docker lab Prometheus container."
  type        = number
  default     = 19090
}

variable "blackbox_port" {
  description = "Host port for the Docker lab blackbox exporter container."
  type        = number
  default     = 19115
}
