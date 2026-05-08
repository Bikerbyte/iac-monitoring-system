# Instance Down

## Symptoms

- Prometheus `up` 顯示 `0`。
- Grafana 的 Linux Node Overview 出現 DOWN。
- 可能同時看到 `InstanceDown` alert。

## Possible Impact

- Prometheus 無法收集該 server 的 metrics。
- 服務可能真的離線，也可能只是網路或 exporter port 不通。

## Initial Checks

```bash
ping <target-ip>
ssh <user>@<target-ip>
curl http://<target-ip>:8000/metrics
curl http://<target-ip>:9100/metrics
```

## Investigation Commands

```bash
uptime
systemctl status monitor-agent
systemctl status node_exporter
journalctl -u monitor-agent --no-pager -n 100
journalctl -u node_exporter --no-pager -n 100
ss -lntp | grep -E ':8000|:9100'
```

## Common Root Causes

- VM 關機、重開機中，或 cloud instance 被停用。
- Security group、防火牆或 routing 阻擋 `8000` / `9100`。
- `monitor-agent` 或 `node_exporter` 服務異常。
- Prometheus target IP 與 Terraform inventory 不一致。

## Fix / Mitigation

```bash
sudo systemctl restart monitor-agent
sudo systemctl restart node_exporter
```

如果 target IP 改了，先更新 Terraform variables，再重新產生 inventory 並部署 stack：

```bash
make server-apply
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

## Validation

```bash
curl http://<target-ip>:8000/metrics
curl http://<target-ip>:9100/metrics
curl http://localhost:9090/api/v1/targets
```

## Prevention

- 變更 VM IP、security group 或 firewall 後，同步更新 Terraform vars、README 與操作文件。
- 讓 `monitor-agent` 和 `node_exporter` 維持 systemd enabled。
- 對 Prometheus targets 定期執行 `make verify-stack`。

