#!/usr/bin/env bash
# Bring up a local k3d cluster, install kube-prometheus-stack with our values,
# then apply the monitor-agent DaemonSet / ServiceMonitor / PrometheusRule.
set -euo pipefail

CLUSTER="${1:-iac-monitoring}"
AGENT_IMAGE="${2:-monitor-agent:dev}"
NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"
CHART_VERSION="${CHART_VERSION:-65.0.0}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required binary: $1" >&2
    exit 1
  }
}
require k3d
require kubectl
require helm
require docker

if ! k3d cluster list | awk '{print $1}' | grep -qx "$CLUSTER"; then
  echo ">>> creating k3d cluster: $CLUSTER"
  k3d cluster create "$CLUSTER" \
    --port "${GRAFANA_PORT}:3000@loadbalancer" \
    --port "${PROMETHEUS_PORT}:9090@loadbalancer" \
    --port "${ALERTMANAGER_PORT}:9093@loadbalancer" \
    --wait
else
  echo ">>> k3d cluster $CLUSTER already exists"
fi

echo ">>> loading agent image into k3d"
docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1 || {
  echo "agent image $AGENT_IMAGE not found — run 'make build-agent-image' first" >&2
  exit 1
}
k3d image import "$AGENT_IMAGE" -c "$CLUSTER"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ">>> creating placeholder external-targets secret (empty)"
kubectl -n "$NAMESPACE" create secret generic iac-external-targets \
  --from-literal=external-targets.yaml="[]" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">>> creating Grafana dashboard ConfigMap"
kubectl -n "$NAMESPACE" create configmap iac-grafana-dashboards \
  --from-file=ansible/files/grafana/dashboards/ \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">>> helm repo add prometheus-community"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo ">>> installing kube-prometheus-stack ($CHART_VERSION)"
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  --values k8s/helm/values.yaml \
  --wait

echo ">>> applying monitor-agent manifests"
kubectl apply -f k8s/manifests/monitor-agent-daemonset.yaml
kubectl apply -f k8s/manifests/servicemonitor.yaml
kubectl apply -f k8s/manifests/prometheusrule.yaml

echo ">>> done"
echo "Grafana:      http://localhost:${GRAFANA_PORT}  (admin / admin)"
echo "Prometheus:   http://localhost:${PROMETHEUS_PORT}"
echo "Alertmanager: http://localhost:${ALERTMANAGER_PORT}"
