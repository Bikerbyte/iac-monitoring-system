# IaC Monitoring System 使用教學

這份文件用來操作 `iac-monitoring-system` 的 VM/Linux monitoring workflow。主線是 Server Agent Mode：Terraform 管 Linux server inventory 或 AWS EC2，Ansible 派送 Python monitor-agent、Node Exporter，以及 control node 上的 Docker-based Prometheus/Grafana/Alertmanager stack。

Docker Target Mode 仍保留，但定位是快速 local demo，用來展示 Terraform 管理 Docker app targets 與 Prometheus blackbox scrape。

## 開始前確認位置

以下指令都假設你在專案根目錄執行，也就是看得到 `infra/`、`ansible/`、`agent/`、`docs/` 的那一層。

```bash
cd iac-monitoring-system
ls
```

應該會看到：

```text
ansible  agent  docs  infra
```

主要 Terraform 目錄：

```text
infra/server/terraform/  Server Agent Mode，既有 Linux servers 或 AWS EC2
infra/docker/terraform/  Docker Target Mode，本機 Docker app containers demo
```

## Server Agent Mode

Server Agent Mode 會部署兩種 target-side monitoring output：

- Python agent：DNS/TCP/custom checks、latency、retry attempts、JSON event logs、`:8000/metrics`
- Node Exporter：CPU、memory、disk、filesystem、load、network、`:9100/metrics`

control node 上的 monitoring stack 維持 Docker-based deployment：

- Prometheus：`http://localhost:9090`
- Grafana：`http://localhost:3000`
- Alertmanager：`http://localhost:9093`

### 設定 Terraform inventory

先複製範例設定：

```bash
cp infra/server/terraform/terraform.tfvars.example infra/server/terraform/terraform.tfvars
```

編輯 `infra/server/terraform/terraform.tfvars`。既有 Linux servers 可以用這種格式：

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

`ssh_private_key_file = ""` 代表 inventory 不指定 key，Ansible 可以搭配 `--ask-pass`。正式環境建議使用 SSH key。

常用欄位：

- `node_count`
- `enable_aws_resources`
- `server_hosts[*].ip_address`
- `ansible_user`
- `ssh_private_key_file`
- `ssh_public_key_file`
- `aws_region`
- `aws_ami_id`
- `aws_instance_type`
- `allowed_ssh_cidr_blocks`
- `allowed_monitoring_cidr_blocks`

AWS/security group 會用到這些 monitoring ports：

```text
3000  Grafana
8000  Python monitor-agent metrics
9090  Prometheus
9093  Alertmanager
9100  Node Exporter metrics
```

真的開 AWS 前，請把 `allowed_ssh_cidr_blocks` 和 `allowed_monitoring_cidr_blocks` 從 `0.0.0.0/0` 改成自己的固定 IP，例如 `["203.0.113.10/32"]`。

### 產生 inventory

```bash
terraform -chdir=infra/server/terraform init
terraform -chdir=infra/server/terraform plan
terraform -chdir=infra/server/terraform apply
terraform -chdir=infra/server/terraform output
```

Terraform 會產生 `ansible/inventory.ini`，並輸出 server IP、SSH connection info、`monitor-agent` targets、Node Exporter targets，以及 Prometheus/Grafana/Alertmanager URLs。

### 部署 agent 與 monitoring stack

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

也可以一次跑完：

```bash
make server-up ANSIBLE_FLAGS="--ask-become-pass"
```

AWS EC2 demo flow：

```bash
cp infra/server/terraform/terraform.tfvars.aws.example infra/server/terraform/terraform.tfvars.aws
# 編輯 AMI、VPC、subnet、CIDR、SSH key
make server-aws-plan
make server-aws-apply
make server-aws-deploy ANSIBLE_FLAGS="--ask-become-pass"
```

如果是 AWS EC2 demo，`server-aws-deploy` 會使用 AWS-safe agent config，避免在 EC2 上檢查本地 LAN gateway。

### 驗證服務狀態

在 target server 上：

```bash
sudo systemctl status monitor-agent
sudo systemctl status node_exporter
sudo journalctl -u monitor-agent --no-pager -n 50
sudo journalctl -u node_exporter --no-pager -n 50
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

Prometheus targets：

```text
http://localhost:9090/targets
```

應該可以看到：

```text
prometheus
monitor-agent
node-exporter
alertmanager
```

Grafana：

```text
http://localhost:3000
admin / admin
Dashboard: IaC Agent Overview
Dashboard: Linux Node Overview
```

### 查看 Python agent log

Python agent log 是 JSON event 格式，會同時寫到檔案與 journald。

```bash
sudo journalctl -u monitor-agent -n 20 --no-pager
sudo tail -f /var/log/monitor-agent.log
```

快速確認事件類型：

```bash
sudo tail -n 20 /var/log/monitor-agent.log | jq -r '.event'
```

常見事件：

- `agent_started`
- `metrics_endpoint_started`
- `metrics_collected`
- `network_check`
- `check_retry_failed`

network check 的重要欄位包含 `event`、`host`、`version`、`failure_type`、`latency_ms`、`attempts`。

## Alerts

Prometheus alert rules 由 Ansible 派送，來源在：

```text
ansible/files/prometheus/rules/linux-alerts.yml
```

目前 alerts：

- `InstanceDown`
- `NodeExporterDown`
- `HighCPUUsage`
- `HighMemoryUsage`
- `DiskAlmostFull`
- `HighLoadAverage`

Alertmanager UI：

```text
http://localhost:9093
```

目前 Alertmanager 使用本機可驗證的 basic receiver，不接 Slack/email。

### 測試 NodeExporterDown

在 target server 上停止 Node Exporter：

```bash
sudo systemctl stop node_exporter
```

確認 Prometheus：

```text
http://localhost:9090/alerts
```

恢復：

```bash
sudo systemctl start node_exporter
```

### 測試 InstanceDown

在 target server 上同時停止兩個 metrics endpoint：

```bash
sudo systemctl stop monitor-agent node_exporter
```

恢復：

```bash
sudo systemctl start monitor-agent node_exporter
```

### 測試 HighCPUUsage

若 target server 有 `stress-ng`：

```bash
sudo stress-ng --cpu "$(nproc)" --timeout 10m
```

沒有 `stress-ng` 時，不建議為了 demo 在正式機器硬跑 busy loop。可以改用測試 VM。

### 測試 HighMemoryUsage

在測試 VM 上使用 `stress-ng`：

```bash
sudo stress-ng --vm 1 --vm-bytes 90% --timeout 10m
```

測完確認 memory 回收：

```bash
free -m
```

### 測試 DiskAlmostFull

只在測試 VM 上操作，避免把正式機器 root filesystem 塞滿：

```bash
df -h
fallocate -l 2G /tmp/iac-disk-test.img
df -h
rm -f /tmp/iac-disk-test.img
```

### 測試 HighLoadAverage

先確認 CPU count：

```bash
nproc
uptime
```

在測試 VM 上用 CPU 或 I/O 壓力製造 load，測完要恢復並觀察：

```bash
uptime
```

更完整的處理流程請看 `runbooks/`。

## Docker Target Mode

Docker Target Mode 是 local demo，不需要 Linux server。Terraform 會建立幾個 HTTP app containers，Ansible 會讓 Prometheus 透過 blackbox exporter 探測 HTTP health。

啟動：

```bash
make docker-up ANSIBLE_FLAGS="--ask-become-pass"
```

調整 target 數量：

```bash
make docker-scale NODE_COUNT=3 ANSIBLE_FLAGS="--ask-become-pass"
```

模擬故障：

```bash
docker stop iac-lab-app-node-01
```

恢復 desired state：

```bash
terraform -chdir=infra/docker/terraform apply
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

清除：

```bash
make docker-down ANSIBLE_FLAGS="--ask-become-pass"
```

## Backup and Restore

這個 repo 不放多支 backup/restore scripts。正式設定以 Git + Ansible template 為來源；如果現場有 runtime 變更，再手動備份。

備份 control node 上的 monitoring config：

```bash
backup_dir="backups/manual-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
sudo cp /opt/iac-monitoring-stack/prometheus.yml "$backup_dir/" 2>/dev/null || true
sudo cp /opt/iac-monitoring-stack/alertmanager.yml "$backup_dir/" 2>/dev/null || true
sudo cp -a /opt/iac-monitoring-stack/rules "$backup_dir/" 2>/dev/null || true
sudo cp -a /opt/iac-monitoring-stack/grafana/dashboards "$backup_dir/" 2>/dev/null || true
```

用 repo 內設定還原：

```bash
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
make verify-stack
```

若要還原手動備份，先確認內容，再複製回 `/opt/iac-monitoring-stack/`，接著重啟相關 container 或重跑 Ansible。

## Troubleshooting

### Terraform 目錄錯誤

如果看到：

```text
Terraform initialized in an empty directory!
```

代表你目前不在有 `.tf` 檔案的 Terraform 目錄。回到專案根目錄後再進入正確路徑：

```bash
cd /home/ianhsu/Projects/iac-monitoring-system
ls infra/server/terraform/*.tf
```

### Ansible 連不上 target

```bash
cat ansible/inventory.ini
ansible -i ansible/inventory.ini monitoring_agents -m ping
```

確認：

- IP 是否正確
- SSH user 是否正確
- key path 或 `--ask-pass` 是否符合登入方式
- target server 是否允許 sudo

### Prometheus 看不到 target

```bash
terraform -chdir=infra/server/terraform output
cat ansible/inventory.ini
curl http://localhost:9090/api/v1/targets
```

如果 inventory 改了，重新部署 stack：

```bash
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

### Node Exporter 沒資料

```bash
sudo systemctl status node_exporter
sudo journalctl -u node_exporter --no-pager -n 100
curl http://localhost:9100/metrics | grep node_cpu_seconds_total
```

### Python agent 沒資料

```bash
sudo systemctl status monitor-agent
sudo journalctl -u monitor-agent --no-pager -n 100
sudo tail -n 50 /var/log/monitor-agent.log
curl http://localhost:8000/metrics
```

### Grafana 沒 dashboard

```bash
docker logs grafana --tail 100
ls -l /opt/iac-monitoring-stack/grafana/dashboards
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

### Alertmanager 沒啟動

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker logs alertmanager --tail 100
curl http://localhost:9093/-/healthy
```

## 清除 AWS Server Agent Mode

如果你有打開 `enable_aws_resources=true` 建立 EC2，練習完請刪除，避免產生費用：

```bash
make server-aws-destroy
```
