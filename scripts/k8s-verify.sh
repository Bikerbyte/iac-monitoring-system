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
TARGETS_JSON_FILE="$(mktemp)"
trap 'kill $PF_PID 2>/dev/null || true; rm -f "$TARGETS_JSON_FILE"' EXIT
sleep 3

curl -fsS http://localhost:19090/-/healthy && echo " prometheus healthy"
for attempt in {1..9}; do
  curl -fsS http://localhost:19090/api/v1/targets -o "$TARGETS_JSON_FILE"
  if python3 - "$TARGETS_JSON_FILE" <<'PY'
import json
import sys

required = {
    "serviceMonitor/monitoring/monitor-agent/0",
    "serviceMonitor/monitoring/kube-prometheus-stack-prometheus-node-exporter/0",
}

with open(sys.argv[1], encoding="utf-8") as targets_file:
    data = json.load(targets_file)
targets = data["data"]["activeTargets"]
print(f"active targets: {len(targets)}")
for target in targets:
    print(" -", target["scrapePool"], target["health"])

health_by_pool = {target["scrapePool"]: target["health"] for target in targets}
missing_or_unhealthy = [
    pool for pool in sorted(required) if health_by_pool.get(pool) != "up"
]
if missing_or_unhealthy:
    print("required targets not up:", ", ".join(missing_or_unhealthy), file=sys.stderr)
    sys.exit(1)
PY
  then
    exit 0
  fi

  if [ "$attempt" -eq 9 ]; then
    exit 1
  fi
  echo ">>> waiting for required targets to become UP (attempt $attempt/9)"
  sleep 10
done
