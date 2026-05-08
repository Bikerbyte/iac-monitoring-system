#!/usr/bin/env bash
set -u

INVENTORY_FILE="${INVENTORY_FILE:-ansible/inventory.ini}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"

failures=0

pass() {
  echo "[OK] $1"
}

fail() {
  echo "[FAIL] $1"
  failures=$((failures + 1))
}

warn() {
  echo "[WARN] $1"
}

check_url() {
  local name="$1"
  local url="$2"

  if curl -fsS --max-time 5 "$url" >/dev/null; then
    pass "$name reachable: $url"
  else
    fail "$name not reachable: $url"
  fi
}

check_metric() {
  local name="$1"
  local url="$2"
  local metric="$3"

  if curl -fsS --max-time 5 "$url" | grep -q "$metric"; then
    pass "$name exposes $metric"
  else
    fail "$name missing $metric at $url"
  fi
}

load_targets_from_inventory() {
  awk '
    /^\[monitoring_agents\]/ { in_group=1; next }
    /^\[/ { in_group=0 }
    in_group && NF > 0 && $1 !~ /^#/ {
      target=$1
      for (i=1; i<=NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, parts, "=")
          target=parts[2]
        }
      }
      print target
    }
  ' "$INVENTORY_FILE"
}

echo "Checking local monitoring stack"
check_url "Prometheus" "$PROMETHEUS_URL/-/healthy"
check_url "Grafana" "$GRAFANA_URL/api/health"
check_url "Alertmanager" "$ALERTMANAGER_URL/-/healthy"

if [[ ! -f "$INVENTORY_FILE" ]]; then
  warn "Inventory file not found: $INVENTORY_FILE"
else
  mapfile -t targets < <(load_targets_from_inventory)

  if [[ "${#targets[@]}" -eq 0 ]]; then
    warn "No monitoring_agents targets found in $INVENTORY_FILE"
  else
    echo "Checking target metrics endpoints"
    for target in "${targets[@]}"; do
      check_metric "monitor-agent on $target" "http://$target:8000/metrics" "monitor_agent"
      check_metric "node_exporter on $target" "http://$target:9100/metrics" "node_cpu_seconds_total"
    done
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  echo "Monitoring stack verification failed with $failures issue(s)."
  exit 1
fi

echo "Monitoring stack verification passed."

