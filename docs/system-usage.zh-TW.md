# IaC Monitoring System 操作說明

`iac-monitoring-system` 的 Server Agent Mode：  

Terraform 管 Linux server inventory 或 AWS EC2  

Ansible 把 Python monitor-agent、Node Exporter 推上去，control node 跑 Docker-based 的 Prometheus/Grafana/Alertmanager。

Docker Target Mode 保留作為本機 demo 用。

## 確認工作目錄

所有指令都在專案根目錄執行：

```bash
cd iac-monitoring-system
ls
```

應該看到：

```text
ansible  agent  docs  infra
```

兩個 Terraform 目錄：

```text
infra/server/terraform/  Server Agent Mode，既有 Linux servers 或 AWS EC2
infra/docker/terraform/  Docker Target Mode，本機 demo 用
```

## Server Agent Mode

每台 target server 跑兩個東西：

- **Python agent**：DNS/TCP 檢查、latency、retry 紀錄、JSON log，暴露 `:8000/metrics`
- **Node Exporter**：標準 Linux metrics（CPU、memory、disk、network），暴露 `:9100/metrics`

Control node 跑 Docker 的 monitoring stack：

```text
Prometheus:    http://localhost:9090
Grafana:       http://localhost:3000
Alertmanager:  http://localhost:9093
```

### 設定 Terraform inventory

複製範例設定：

```bash
cp infra/server/terraform/terraform.tfvars.example infra/server/terraform/terraform.tfvars
```

編輯 `infra/server/terraform/terraform.tfvars`，既有 Linux server 填這樣：

```hcl
node_count           = 2
enable_aws_resources = false

server_hosts = [
  {
    name                 = "monitor-node-02"
    ip_address           = "192.168.0.146"
    ansible_user         = "deploy"
    ssh_private_key_file = ""
  },
  {
    name                 = "monitor-node-03"
    ip_address           = "192.168.0.235"
    ansible_user         = "deploy"
    ssh_private_key_file = ""
  }
]
```

`ssh_private_key_file = ""` 代表不指定 key，搭配 `--ask-pass` 用密碼登入。正式環境建議用 SSH key。

常用欄位：

| 欄位 | 說明 |
|---|---|
| `node_count` | server 數量 |
| `enable_aws_resources` | 是否開 EC2 |
| `server_hosts[*].ip_address` | server IP |
| `ansible_user` | SSH 登入用戶 |
| `ssh_private_key_file` | SSH key 路徑 |
| `aws_region` / `aws_ami_id` / `aws_instance_type` | AWS 設定 |
| `allowed_ssh_cidr_blocks` | 允許 SSH 的來源 IP |
| `allowed_monitoring_cidr_blocks` | 允許存取 monitoring port 的來源 IP |

開 AWS 前記得把 CIDR 從 `0.0.0.0/0` 改成自己的固定 IP，例如 `["203.0.113.10/32"]`。

Monitoring 用到的 port：

```text
3000  Grafana
8000  Python agent metrics
9090  Prometheus
9093  Alertmanager
9100  Node Exporter
```

### 產生 inventory

```bash
terraform -chdir=infra/server/terraform init
terraform -chdir=infra/server/terraform plan
terraform -chdir=infra/server/terraform apply
terraform -chdir=infra/server/terraform output
```

`output` 會印出 server IP、SSH 連線資訊、agent/Node Exporter targets、以及 monitoring stack 的本機 URL。

### 部署

密碼登入：

```bash
make server-agent ANSIBLE_FLAGS="--ask-pass --ask-become-pass"
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

SSH key 登入：

```bash
make server-agent ANSIBLE_FLAGS="--ask-become-pass"
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

一次跑完兩個：

```bash
make server-up ANSIBLE_FLAGS="--ask-become-pass"
```

AWS EC2 的話：

```bash
cp infra/server/terraform/terraform.tfvars.aws.example infra/server/terraform/terraform.tfvars.aws
# 填 AMI、VPC、subnet、CIDR、SSH key
make server-aws-plan
make server-aws-apply
make server-aws-deploy ANSIBLE_FLAGS="--ask-become-pass"
```

`server-aws-deploy` 會用 AWS-safe 的 agent config，避免在 EC2 上檢查本地 LAN gateway。

### 確認服務有起來

在 target server 上：

```bash
sudo systemctl status monitor-agent
sudo systemctl status node_exporter
sudo journalctl -u monitor-agent --no-pager -n 50
curl http://localhost:8000/metrics
curl http://localhost:9100/metrics
```

在 control node 上：

```bash
curl http://localhost:9090/-/healthy
curl http://localhost:9093/-/healthy
curl http://localhost:3000/api/health
curl http://<target-ip>:8000/metrics
curl http://<target-ip>:9100/metrics
make verify-stack
```

Prometheus targets 頁面：

```
http://localhost:9090/targets
```

應該要看到 `prometheus`、`monitor-agent`、`node-exporter`、`alertmanager` 都是 UP。

Grafana：

```
http://localhost:3000  (admin / admin)
Dashboard: IaC Agent Overview
Dashboard: Linux Node Overview
```

### 看 agent log

Agent log 是 JSON 格式，同時寫 journald 和本機檔案：

```bash
sudo journalctl -u monitor-agent -n 20 --no-pager
sudo tail -f /var/log/monitor-agent.log
```

快速列出事件類型：

```bash
sudo tail -n 20 /var/log/monitor-agent.log | jq -r '.event'
```

常見事件：`agent_started`、`metrics_endpoint_started`、`metrics_collected`、`network_check`、`check_retry_failed`

`network_check` 裡比較有用的欄位：`failure_type`、`latency_ms`、`attempts`、`ok`。

## Alerts

Rules 放在 `ansible/files/prometheus/rules/linux-alerts.yml`，Ansible 部署時推給 Prometheus：

- `InstanceDown`
- `NodeExporterDown`
- `HighCPUUsage`
- `HighMemoryUsage`
- `DiskAlmostFull`
- `HighLoadAverage`

Alertmanager UI：`http://localhost:9093`（目前用 basic receiver，沒接 Slack/email）

### 測試 NodeExporterDown

在 target server 上：

```bash
sudo systemctl stop node_exporter
```

去 `http://localhost:9090/alerts` 確認 alert 有觸發，測完恢復：

```bash
sudo systemctl start node_exporter
```

### 測試 InstanceDown

同時停掉兩個 metrics endpoint：

```bash
sudo systemctl stop monitor-agent node_exporter
# 恢復
sudo systemctl start monitor-agent node_exporter
```

### 測試 HighCPUUsage

有裝 `stress-ng` 的話：

```bash
sudo stress-ng --cpu "$(nproc)" --timeout 10m
```

沒有的話建議在測試 VM 上操作，不要在正式機器跑 busy loop。

### 測試 HighMemoryUsage

在測試 VM 上：

```bash
sudo stress-ng --vm 1 --vm-bytes 90% --timeout 10m
free -m  # 測完確認有回收
```

### 測試 DiskAlmostFull

只在測試 VM 上做，不要塞正式機器：

```bash
df -h
fallocate -l 2G /tmp/iac-disk-test.img
df -h
rm -f /tmp/iac-disk-test.img
```

### 測試 HighLoadAverage

```bash
nproc   # 確認 CPU 數量
uptime  # 看目前 load
```

在測試 VM 上製造 CPU 或 I/O 壓力，詳細流程看 `runbooks/`。

## Docker Target Mode

不需要 Linux server，純本機 demo。Terraform 建幾個 HTTP app container，Prometheus 透過 blackbox exporter 探測 HTTP health。

```bash
make docker-up ANSIBLE_FLAGS="--ask-become-pass"
make docker-scale NODE_COUNT=3 ANSIBLE_FLAGS="--ask-become-pass"

# 模擬故障
docker stop iac-lab-app-node-01

# 恢復
terraform -chdir=infra/docker/terraform apply
make server-stack ANSIBLE_FLAGS="--ask-become-pass"

# 清掉
make docker-down ANSIBLE_FLAGS="--ask-become-pass"
```

## 備份與還原

設定以 Git + Ansible template 為主，重跑 Ansible 就是還原。有手動改過 runtime 設定的話，先備份：

```bash
backup_dir="backups/manual-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
sudo cp /opt/iac-monitoring-stack/prometheus.yml "$backup_dir/" 2>/dev/null || true
sudo cp /opt/iac-monitoring-stack/alertmanager.yml "$backup_dir/" 2>/dev/null || true
sudo cp -a /opt/iac-monitoring-stack/rules "$backup_dir/" 2>/dev/null || true
sudo cp -a /opt/iac-monitoring-stack/grafana/dashboards "$backup_dir/" 2>/dev/null || true
```

用 repo 還原：

```bash
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
make verify-stack
```

手動備份還原的話，確認內容後複製回 `/opt/iac-monitoring-stack/`，再重啟相關 container 或重跑 Ansible。

## Troubleshooting

**Terraform 看到 "initialized in an empty directory"**

代表你不在有 `.tf` 的目錄，回到根目錄：

```bash
cd /home/ianhsu/Projects/iac-monitoring-system
ls infra/server/terraform/*.tf
```

**Ansible 連不上 target**

```bash
cat ansible/inventory.ini
ansible -i ansible/inventory.ini monitoring_agents -m ping
```

確認 IP 對、SSH user 對、key 或 `--ask-pass` 符合登入方式、target 允許 sudo。

**Prometheus 看不到 target**

```bash
terraform -chdir=infra/server/terraform output
cat ansible/inventory.ini
curl http://localhost:9090/api/v1/targets
```

Inventory 改了要重跑：

```bash
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

**Node Exporter 沒資料**

```bash
sudo systemctl status node_exporter
sudo journalctl -u node_exporter --no-pager -n 100
curl http://localhost:9100/metrics | grep node_cpu_seconds_total
```

**Python agent 沒資料**

```bash
sudo systemctl status monitor-agent
sudo journalctl -u monitor-agent --no-pager -n 100
sudo tail -n 50 /var/log/monitor-agent.log
curl http://localhost:8000/metrics
```

**Grafana 沒 dashboard**

```bash
docker logs grafana --tail 100
ls -l /opt/iac-monitoring-stack/grafana/dashboards
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

**Alertmanager 沒起來**

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker logs alertmanager --tail 100
curl http://localhost:9093/-/healthy
```

## 清除 AWS 資源

如果有開 `enable_aws_resources=true` 建 EC2，練習完記得刪掉：

```bash
make server-aws-destroy
```