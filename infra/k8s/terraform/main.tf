terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# The k3d cluster itself is created via the k3d CLI through a null_resource.
# k3d has no first-class Terraform provider; this is the idiomatic way to
# wrap external CLI steps that the rest of the IaC then depends on.
resource "null_resource" "k3d_cluster" {
  triggers = {
    cluster_name      = var.cluster_name
    grafana_port      = tostring(var.grafana_port)
    prometheus_port   = tostring(var.prometheus_port)
    alertmanager_port = tostring(var.alertmanager_port)
  }

  provisioner "local-exec" {
    command = <<-EOT
      if ! k3d cluster list | awk '{print $1}' | grep -qx "${var.cluster_name}"; then
        k3d cluster create "${var.cluster_name}" \
          --port "${var.grafana_port}:3000@loadbalancer" \
          --port "${var.prometheus_port}:9090@loadbalancer" \
          --port "${var.alertmanager_port}:9093@loadbalancer" \
          --wait
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.triggers.cluster_name} || true"
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = "k3d-${var.cluster_name}"
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = "k3d-${var.cluster_name}"
  }
}

resource "kubernetes_namespace" "monitoring" {
  depends_on = [null_resource.k3d_cluster]

  metadata {
    name = "monitoring"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [kubernetes_namespace.monitoring]

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [file("${path.module}/../../../k8s/helm/values.yaml")]

  timeout = 600
  wait    = true
}
