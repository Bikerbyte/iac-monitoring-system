# High Memory

## Symptoms

- `HighMemoryUsage` alert firing。
- Grafana memory usage 長時間高於 90%。
- 服務可能被 OOM killer 結束。

## Possible Impact

- 應用變慢或重啟。
- SSH 操作延遲。
- systemd service 因 OOM 失敗。

## Initial Checks

```bash
free -m
top
ps aux --sort=-%mem | head
```

## Investigation Commands

```bash
dmesg -T | grep -i oom
journalctl --since "30 minutes ago" --no-pager | grep -i oom
systemctl status <service-name>
```

## Common Root Causes

- 應用 memory leak。
- 批次工作吃掉大量 memory。
- Docker container 沒有限制 memory。
- VM memory 規格不足。

## Fix / Mitigation

```bash
sudo systemctl restart <service-name>
```

如果是 container，先確認 container 名稱與影響範圍：

```bash
docker stats --no-stream
docker restart <container-name>
```

## Validation

```bash
free -m
curl http://<target-ip>:9100/metrics | grep node_memory_MemAvailable_bytes
```

## Prevention

- 對長跑服務觀察 memory baseline。
- 對 container 設定 memory limit。
- 發現 leak 時補應用層修正，不只靠 restart。

