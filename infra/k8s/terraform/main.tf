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

locals {
  repo_root             = "${path.module}/../../.."
  dashboards_dir        = "${local.repo_root}/ansible/files/grafana/dashboards"
  helm_values_file      = "${local.repo_root}/k8s/helm/values.yaml"
  manifest_daemonset    = "${local.repo_root}/k8s/manifests/monitor-agent-daemonset.yaml"
  manifest_servicemon   = "${local.repo_root}/k8s/manifests/servicemonitor.yaml"
  manifest_prometheusrl = "${local.repo_root}/k8s/manifests/prometheusrule.yaml"
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

# Import the locally-built monitor-agent image into k3d so the DaemonSet can
# pull it with IfNotPresent without leaving the host. Must complete before
# the DaemonSet is applied; otherwise pods stall on ImagePullBackOff.
resource "null_resource" "agent_image_import" {
  depends_on = [null_resource.k3d_cluster]

  triggers = {
    cluster_name = var.cluster_name
    agent_image  = var.agent_image
  }

  provisioner "local-exec" {
    command = <<-EOT
      if ! docker image inspect "${var.agent_image}" >/dev/null 2>&1; then
        echo "agent image ${var.agent_image} not found locally — run 'make build-agent-image' first" >&2
        exit 1
      fi
      k3d image import "${var.agent_image}" -c "${var.cluster_name}"
    EOT
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

# Placeholder Secret consumed by prometheus.additionalScrapeConfigsSecret in
# values.yaml. Operators replace data["external-targets.yaml"] out-of-band
# (kubectl apply) when adding VM targets; lifecycle ignores data so a later
# `terraform apply` won't revert those edits.
resource "kubernetes_secret" "external_targets" {
  depends_on = [kubernetes_namespace.monitoring]

  metadata {
    name      = "iac-external-targets"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "external-targets.yaml" = "[]"
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# Grafana dashboard JSON shared with VM mode, surfaced via grafana
# dashboardsConfigMaps.default in values.yaml.
resource "kubernetes_config_map" "grafana_dashboards" {
  depends_on = [kubernetes_namespace.monitoring]

  metadata {
    name      = "iac-grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    for fname in fileset(local.dashboards_dir, "*.json") :
    fname => file("${local.dashboards_dir}/${fname}")
  }
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [
    kubernetes_namespace.monitoring,
    kubernetes_secret.external_targets,
    kubernetes_config_map.grafana_dashboards,
  ]

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [file(local.helm_values_file)]

  timeout = 600
  wait    = true
}

# monitor-agent DaemonSet + ServiceMonitor + PrometheusRule. Applied via
# kubectl because ServiceMonitor / PrometheusRule are CRDs only registered
# once the kube-prometheus-stack release lands — the kubernetes_manifest
# resource would need those CRD schemas at plan time and fail.
resource "null_resource" "monitor_agent_manifests" {
  depends_on = [
    helm_release.kube_prometheus_stack,
    null_resource.agent_image_import,
  ]

  triggers = {
    cluster_context = "k3d-${var.cluster_name}"
    daemonset       = filesha256(local.manifest_daemonset)
    servicemonitor  = filesha256(local.manifest_servicemon)
    prometheusrule  = filesha256(local.manifest_prometheusrl)
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context "k3d-${var.cluster_name}" apply \
        -f "${local.manifest_daemonset}" \
        -f "${local.manifest_servicemon}" \
        -f "${local.manifest_prometheusrl}"
    EOT
  }
}
