# Node Exporter Down

## Symptoms

- `NodeExporterDown` alert firing。
- `up{job="node-exporter"}` 顯示 `0`。
- Grafana Linux CPU、memory、disk、load panel 沒資料。

## Possible Impact

- 無法觀察 Linux host 標準 metrics。
- Python agent 可能仍可回報 DNS/TCP/custom checks，但 CPU、memory、disk 等 node-level 指標會中斷。

## Initial Checks

```bash
systemctl status node_exporter
curl http://localhost:9100/metrics
```

從 control node 檢查：

```bash
curl http://<target-ip>:9100/metrics
```

## Investigation Commands

```bash
journalctl -u node_exporter --no-pager -n 100
ss -lntp | grep ':9100'
id node_exporter
ls -l /usr/local/bin/node_exporter
```

## Common Root Causes

- `node_exporter` service 沒啟動或 binary 不存在。
- target firewall 阻擋 `9100`。
- systemd unit 被手動修改後未 reload。
- CPU architecture 不在目前 Ansible role 支援清單。

## Fix / Mitigation

```bash
sudo systemctl daemon-reload
sudo systemctl restart node_exporter
sudo systemctl enable node_exporter
```

如果 binary 或 service file 遺失，重跑 Ansible：

```bash
make server-agent ANSIBLE_FLAGS="--ask-become-pass"
```

## Validation

```bash
curl http://localhost:9100/metrics | grep node_cpu_seconds_total
curl http://<target-ip>:9100/metrics | grep node_memory_MemAvailable_bytes
```

## Prevention

- 不手動覆蓋 `/usr/local/bin/node_exporter` 與 systemd unit。
- Node Exporter 版本升級由 Ansible role 管理。
- 防火牆規則變更時同步確認 `9100`。

