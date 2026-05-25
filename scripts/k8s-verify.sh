#!/usr/bin/env bash
# Smoke-check the k8s monitoring stack.
set -euo pipefail

NAMESPACE="monitoring"

echo ">>> namespace pods"
kubectl -n "$NAMESPACE" get pods

echo
echo ">>> monitor-agent DaemonSet ready count"
kubectl -n "$NAMESPACE" rollout status ds/monitor-agent --timeout=60s

echo
echo ">>> Prometheus target health (via port-forward)"
kubectl -n "$NAMESPACE" port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

curl -fsS http://localhost:19090/-/healthy && echo " prometheus healthy"
curl -fsS http://localhost:19090/api/v1/targets \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d["data"]["activeTargets"]; print(f"active targets: {len(a)}"); [print(" -", t["scrapePool"], t["health"]) for t in a]'
