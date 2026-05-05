#!/usr/bin/env bash
set -euo pipefail

INVENTORY="${INVENTORY:-ansible/inventory.ini}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

echo "[1/6] Ansible can reach monitoring agents"
ansible -i "$INVENTORY" monitoring_agents -m ping

echo "[2/6] monitor-agent service is active"
ansible -i "$INVENTORY" monitoring_agents -b -m command -a "systemctl is-active monitor-agent"

echo "[3/6] monitor-agent metrics endpoint responds on each server"
ansible -i "$INVENTORY" monitoring_agents -m uri -a "url=http://127.0.0.1:8000/metrics status_code=200"

echo "[4/6] monitor-agent JSON logs are parseable"
ansible -i "$INVENTORY" monitoring_agents -b -m shell -a "tail -n 10 /var/log/monitor-agent.log | python3 -c 'import json,sys; [json.loads(line) for line in sys.stdin if line.strip()]'"

echo "[5/6] Prometheus and Grafana health checks"
curl -fsS "$PROMETHEUS_URL/-/ready" >/dev/null
curl -fsS "$GRAFANA_URL/api/health" | jq -e '.database == "ok"' >/dev/null

echo "[6/6] Prometheus sees monitor-agent targets as up"
curl -fsS "$PROMETHEUS_URL/api/v1/targets?state=active" \
  | jq -e '[.data.activeTargets[] | select(.labels.job == "monitor-agent")] | length > 0 and all(.[]; .health == "up")' >/dev/null

echo "Smoke check passed."
