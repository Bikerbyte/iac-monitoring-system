# Disk Full

## Symptoms

- `DiskAlmostFull` alert firing。
- Grafana filesystem usage 接近或超過 85%。
- 應用寫檔、log rotate、package install 開始失敗。

## Possible Impact

- systemd service 無法寫 log 或啟動。
- Prometheus / agent / OS package 操作可能失敗。
- 嚴重時 VM 會變得不穩定。

## Initial Checks

```bash
df -h
df -ih
```

## Investigation Commands

```bash
sudo du -xh /var | sort -h | tail -20
sudo du -xh /opt | sort -h | tail -20
journalctl --disk-usage
sudo find /var/log -type f -size +100M -ls
```

## Common Root Causes

- `/var/log` 或 application log 成長太快。
- Docker images、containers 或 volumes 沒清理。
- Prometheus TSDB retention 設太久或資料量變大。
- 暫存檔或備份檔放在 root filesystem。

## Fix / Mitigation

先確認檔案用途再清理，不要直接刪未知目錄：

```bash
sudo journalctl --vacuum-time=7d
sudo logrotate -f /etc/logrotate.conf
docker system df
docker image prune
```

如果是 Prometheus 資料量，先確認 retention 設定與磁碟規劃。

## Validation

```bash
df -h
curl http://<target-ip>:9100/metrics | grep node_filesystem_avail_bytes
```

## Prevention

- 保留 logrotate 設定。
- Prometheus retention 維持合理值。
- 大檔、備份和暫存資料不要長期放在 root filesystem。

