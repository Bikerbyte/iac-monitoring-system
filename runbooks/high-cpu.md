# High CPU

## Symptoms

- `HighCPUUsage` alert firing。
- Grafana CPU usage 長時間高於 85%。
- SSH 或服務回應變慢。

## Possible Impact

- 服務延遲升高。
- monitoring agent scrape timeout。
- 系統負載持續累積時可能影響其他服務。

## Initial Checks

```bash
uptime
top
ps aux --sort=-%cpu | head
```

## Investigation Commands

```bash
pidstat 1 5
systemctl --type=service --state=running
journalctl --since "30 minutes ago" --no-pager | tail -200
```

如果沒有 `pidstat`，先用 `top` 和 `ps` 即可。

## Common Root Causes

- 應用 process busy loop。
- 壓測、批次工作或 package build。
- Docker container 使用過多 CPU。
- VM 規格太小或 CPU credit 用完。

## Fix / Mitigation

```bash
sudo systemctl restart <service-name>
```

如果是可預期批次工作，先確認是否能降頻、錯峰或限制資源。不要直接 kill process，除非已確認影響範圍。

## Validation

```bash
uptime
ps aux --sort=-%cpu | head
curl http://<target-ip>:9100/metrics | grep node_cpu_seconds_total
```

## Prevention

- 對批次工作設定資源限制或排程。
- 長期 CPU 偏高時調整 VM 規格。
- 新服務上線後觀察 CPU baseline。

