# High Load

## Symptoms

- `HighLoadAverage` alert firing。
- `uptime` 顯示 load average 高於 CPU count。
- CPU 不一定滿載，但系統回應變慢。

## Possible Impact

- process 排隊等待 CPU、disk I/O 或其他 kernel resource。
- SSH、agent scrape、應用回應延遲升高。

## Initial Checks

```bash
uptime
nproc
top
```

## Investigation Commands

```bash
ps -eo state,pid,ppid,cmd,%cpu,%mem --sort=state | head -40
iostat -xz 1 5
vmstat 1 5
```

如果沒有 `iostat`，可以先用 `top` 觀察 `%wa` 和 process state。

## Common Root Causes

- CPU-bound process 太多。
- Disk I/O wait 過高。
- 大量 process 卡在 uninterruptible sleep。
- VM 規格不足或同機服務太多。

## Fix / Mitigation

- 如果是 CPU-bound，先找出高 CPU process 並確認是否可重啟或降載。
- 如果是 I/O wait，先暫停大量讀寫工作，並檢查磁碟空間與 storage latency。
- 如果是服務異常造成 process 堆積，重啟該服務前先保留 log。

```bash
journalctl -u <service-name> --no-pager -n 200
sudo systemctl restart <service-name>
```

## Validation

```bash
uptime
curl http://<target-ip>:9100/metrics | grep node_load5
```

## Prevention

- 對批次工作錯峰。
- 觀察 load、CPU、disk I/O 一起判斷，不只看單一數字。
- 長期高 load 時調整服務分布或 VM 規格。

