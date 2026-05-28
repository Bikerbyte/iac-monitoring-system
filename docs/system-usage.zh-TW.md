# IaC Monitoring System 操作說明

這份文件是操作 runbook，不是完整架構介紹。照做時先選一條路徑，不要混跑。

目前專案有三條路：

| 路徑 | 用途 | 會不會開 AWS |
|---|---|---|
| A. AWS EC2 Server Agent Mode | 真的建立一台 Linux VM，部署 agent / Node Exporter | 會 |
| B. Existing Linux Server Mode | 用你已經有的 Linux server | 不會 |
| C. Kubernetes Mode | 本機 k3d + Helm 建監控 stack，可選擇加上外部 VM targets | 不會 |

多數情況請走 **A. AWS EC2 Server Agent Mode** 或 **B. Existing Linux Server Mode**。
Kubernetes Mode 主要用於容器化監控流程；若要監控 Linux VM，請搭配 A 或 B 路徑。

## 0. 開始前

所有指令都在專案根目錄跑：

```bash
cd <repo-root>/iac-monitoring-system
```

確認工具：

```bash
terraform version
ansible --version
docker --version
```

control node 指的是你本機，也就是跑 Ansible、Docker、Prometheus、Grafana、Alertmanager 的這台機器。

target server 指的是被監控的 Linux VM。target server 上會跑：

- `monitor-agent`：Python agent，`http://<target-ip>:8000/metrics`，同時寫 JSON log
- `node_exporter`：Linux metrics，`http://<target-ip>:9100/metrics`

control node 上會跑：

- Prometheus：`http://localhost:9090`
- Grafana：`http://localhost:3000`
- Alertmanager：`http://localhost:9093`

## A. AWS EC2 Server Agent Mode

這條路會建立 AWS EC2。不要同時跑 `make vm-apply`，那是給既有 Linux server / mock inventory 用的。

### A1. 準備 AWS tfvars

```bash
cp infra/vm/terraform/terraform.tfvars.aws.example infra/vm/terraform/terraform.tfvars.aws
```

確認目前 public IP：

```bash
curl -fsS https://checkip.amazonaws.com
```

編輯：

```text
infra/vm/terraform/terraform.tfvars.aws
```

至少確認這些欄位：

```hcl
node_count           = 1
enable_aws_resources = true

aws_region        = "ap-northeast-1"
aws_ami_id        = "ami-0555235cac92fff3f"
aws_instance_type = "t3.micro"

ansible_user         = "ubuntu"
ssh_public_key_file  = "~/.ssh/id_rsa.pub"
ssh_private_key_file = "~/.ssh/id_rsa"

aws_vpc_id    = "vpc-0ded4d396050e8f97"
aws_subnet_id = "subnet-0f78ad2fac57a4d7f"

allowed_ssh_cidr_blocks        = ["你的-public-ip/32"]
allowed_monitoring_cidr_blocks = ["你的-public-ip/32"]
```

這個 repo 目前會開這些 port：

```text
22    SSH
8000  Python monitor-agent metrics
9100  Node Exporter metrics
9090  Prometheus
9093  Alertmanager
3000  Grafana
```

### A2. 建立 EC2 與 inventory

先看 plan：

```bash
make vm-aws-plan
```

確認只會建立預期資源後再 apply：

```bash
make vm-aws-apply
```

確認 Terraform output：

```bash
terraform -chdir=infra/vm/terraform output
```

你應該看到：

```text
system_mode = "aws-ec2"
server_ip_addresses = [...]
monitor_agent_targets = ["<public-ip>:8000"]
node_exporter_targets = ["<public-ip>:9100"]
```

也可以確認 AWS 上的 VM：

```bash
aws ec2 describe-instances \
  --region ap-northeast-1 \
  --filters Name=tag:Project,Values=iac-monitoring-system \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,PublicIp:PublicIpAddress,AZ:Placement.AvailabilityZone}' \
  --output table
```

### A3. 部署 target agent 與本機 control node

EC2 剛建立完時 SSH 可能還沒 ready，等 30 到 60 秒再跑：

```bash
make vm-aws-deploy ANSIBLE_FLAGS="--ask-become-pass"
```

這個 target 會做兩件事：

1. 對 AWS EC2 部署 Python monitor-agent 和 Node Exporter。
2. 在本機 control node 啟動 Docker-based Prometheus/Grafana/Alertmanager。

### A4. 驗證 AWS flow

先看 target server：

```bash
ssh ubuntu@<target-public-ip>
sudo systemctl status monitor-agent
sudo systemctl status node_exporter
curl http://localhost:8000/metrics
curl http://localhost:9100/metrics
```

回到 control node：

```bash
curl http://localhost:9090/-/healthy
curl http://localhost:9093/-/healthy
curl http://localhost:3000/api/health
curl http://<target-public-ip>:8000/metrics
curl http://<target-public-ip>:9100/metrics
make verify-stack
```

打開：

```text
Prometheus targets: http://localhost:9090/targets
Grafana:            http://localhost:3000  admin / admin
Alertmanager:       http://localhost:9093
```

Prometheus targets 應該看到：

- `prometheus`
- `monitor-agent`
- `node-exporter`
- `alertmanager`

## B. Existing Linux Server Mode

這條路不會開 AWS，只會把你已經有的 Linux server 寫進 inventory。

### B1. 準備 local tfvars

```bash
cp infra/vm/terraform/terraform.tfvars.example infra/vm/terraform/terraform.tfvars
```

編輯：

```text
infra/vm/terraform/terraform.tfvars
```

範例：

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

`ssh_private_key_file = ""` 代表不指定 key。這時 Ansible 要搭配 `--ask-pass`。

### B2. 產生 inventory

```bash
make vm-plan
make vm-apply
```

確認：

```bash
cat ansible/inventory.ini
terraform -chdir=infra/vm/terraform output
```

`system_mode` 應該是：

```text
mock-inventory
```

這個名字表示沒有開 AWS，不代表不能連真實 server。

### B3. 部署

如果用密碼登入：

```bash
make vm-agent ANSIBLE_FLAGS="--ask-pass --ask-become-pass"
make vm-stack ANSIBLE_FLAGS="--ask-become-pass"
```

如果用 SSH key：

```bash
make vm-agent ANSIBLE_FLAGS="--ask-become-pass"
make vm-stack ANSIBLE_FLAGS="--ask-become-pass"
```

### B4. 驗證

在 target server 上：

```bash
sudo systemctl status monitor-agent
sudo systemctl status node_exporter
curl http://localhost:8000/metrics
curl http://localhost:9100/metrics
```

在 control node 上：

```bash
make verify-stack
curl http://localhost:9090/-/healthy
curl http://<target-ip>:8000/metrics
curl http://<target-ip>:9100/metrics
```

## C. Kubernetes Mode

需求：`docker`、`k3d`、`kubectl`、`helm`。

```bash
make build-agent-image          # 建 monitor-agent Docker image
make k8s-up                     # k3d 起 cluster + Helm 裝 kube-prometheus-stack
make k8s-verify                 # smoke check
```

加入外部 VM target（讓同一個 Prometheus 同時監控 k8s + VM）：

```bash
cp k8s/manifests/external-targets-secret.example.yaml k8s/manifests/external-targets-secret.yaml
# 編輯 targets 列表
kubectl -n monitoring apply -f k8s/manifests/external-targets-secret.yaml
```

或用 Terraform 部署（同樣的 k3d + Helm chart，但 IaC 化）：

```bash
terraform -chdir=infra/k8s/terraform init
terraform -chdir=infra/k8s/terraform apply
```

清除：

```bash
make k8s-down
```

## 常用檢查

### 看 Terraform 目前管理什麼

```bash
terraform -chdir=infra/vm/terraform state list
terraform -chdir=infra/vm/terraform output
```

如果有 AWS EC2，state 會看到：

```text
aws_instance.monitor_node[0]
aws_key_pair.lab[0]
aws_security_group.monitoring_lab[0]
local_file.ansible_inventory
```

如果只是 existing server / mock inventory，通常只會看到：

```text
local_file.ansible_inventory
```

### 看 agent log

在 target server：

```bash
sudo journalctl -u monitor-agent -n 50 --no-pager
sudo tail -f /var/log/monitor-agent.log
```

快速看 JSON event：

```bash
sudo tail -n 20 /var/log/monitor-agent.log | jq -r '.event'
```

常見事件：

- `agent_started`
- `metrics_endpoint_started`
- `metrics_collected`
- `network_check`
- `check_retry_failed`

`network_check` 重要欄位：

- `failure_type`
- `latency_ms`
- `attempts`
- `ok`

Prometheus 也會暴露 network check 的診斷 metrics：

```text
monitor_agent_network_check_latency_ms
monitor_agent_network_check_failure
```

Grafana 的 Agent / Linux dashboard 頂部都有 `instance` dropdown。平常用 `All` 看 fleet overview；要查單台時，選該 node 的 `instance`，CPU、memory、network latency、failure breakdown 會一起縮到單台。

### 看 control node containers

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker logs prometheus --tail 100
docker logs grafana --tail 100
docker logs alertmanager --tail 100
```

## Alert 測試

Alert rules 在：

```text
ansible/files/prometheus/rules/linux-alerts.yml
```

Prometheus alerts 頁面：

```text
http://localhost:9090/alerts
```

Alertmanager：

```text
http://localhost:9093
```

### NodeExporterDown

在 target server：

```bash
sudo systemctl stop node_exporter
```

測完恢復：

```bash
sudo systemctl start node_exporter
```

### InstanceDown

在 target server：

```bash
sudo systemctl stop monitor-agent node_exporter
```

測完恢復：

```bash
sudo systemctl start monitor-agent node_exporter
```

### HighCPUUsage

只建議在測試 VM：

```bash
sudo stress-ng --cpu "$(nproc)" --timeout 10m
```

### HighMemoryUsage

只建議在測試 VM：

```bash
sudo stress-ng --vm 1 --vm-bytes 90% --timeout 10m
free -m
```

### DiskAlmostFull

只建議在測試 VM，不要塞正式機器：

```bash
df -h
fallocate -l 2G /tmp/iac-disk-test.img
df -h
rm -f /tmp/iac-disk-test.img
```

更完整的處理流程看：

```text
runbooks/
```

## 備份與還原

設定來源以 Git + Ansible template 為主。正常還原方式是重跑：

```bash
make vm-stack ANSIBLE_FLAGS="--ask-become-pass"
make verify-stack
```

如果有手動改過 `/opt/iac-monitoring-stack`，先備份：

```bash
backup_dir="backups/manual-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
sudo cp /opt/iac-monitoring-stack/prometheus.yml "$backup_dir/" 2>/dev/null || true
sudo cp /opt/iac-monitoring-stack/alertmanager.yml "$backup_dir/" 2>/dev/null || true
sudo cp -a /opt/iac-monitoring-stack/rules "$backup_dir/" 2>/dev/null || true
sudo cp -a /opt/iac-monitoring-stack/grafana/dashboards "$backup_dir/" 2>/dev/null || true
```

## Troubleshooting

### AWS credential 失效

錯誤像這樣：

```text
AuthFailure: AWS was not able to validate the provided access credentials
```

先查：

```bash
aws sts get-caller-identity
env | sort | grep '^AWS_' || true
```

如果 `aws sts` 失敗，先修 AWS CLI credential，再重跑 Terraform。

### Terraform plan 用錯 tfvars

AWS flow 要跑：

```bash
make vm-aws-plan
make vm-aws-apply
```

Existing server flow 才跑：

```bash
make vm-plan
make vm-apply
```

如果 `system_mode` 不是預期值：

```bash
terraform -chdir=infra/vm/terraform output system_mode
```

### Ansible 連不上 target

```bash
cat ansible/inventory.ini
ansible -i ansible/inventory.ini monitoring_agents -m ping
```

檢查：

- IP 是否正確
- SSH user 是否正確
- SSH key path 或 `--ask-pass` 是否符合登入方式
- target server 是否允許 sudo
- AWS security group 是否允許你的 public IP 連 `22`

### Prometheus 看不到 target

```bash
curl http://localhost:9090/api/v1/targets
cat ansible/inventory.ini
terraform -chdir=infra/vm/terraform output
```

inventory 改了就重跑 control node stack：

```bash
make vm-stack ANSIBLE_FLAGS="--ask-become-pass"
```

### Node Exporter 沒資料

在 target server：

```bash
sudo systemctl status node_exporter
sudo journalctl -u node_exporter --no-pager -n 100
curl http://localhost:9100/metrics | grep node_cpu_seconds_total
```

### Python agent 沒資料

在 target server：

```bash
sudo systemctl status monitor-agent
sudo journalctl -u monitor-agent --no-pager -n 100
sudo tail -n 50 /var/log/monitor-agent.log
curl http://localhost:8000/metrics
```

### Grafana 沒 dashboard

在 control node：

```bash
docker logs grafana --tail 100
ls -l /opt/iac-monitoring-stack/grafana/dashboards
make vm-stack ANSIBLE_FLAGS="--ask-become-pass"
```

## 清除 AWS 資源

AWS flow 練完要刪掉，避免持續計費：

```bash
make vm-aws-destroy
```

確認 state 清乾淨：

```bash
terraform -chdir=infra/vm/terraform state list
```
