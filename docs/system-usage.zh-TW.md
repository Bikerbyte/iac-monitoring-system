# IaC Monitoring System 使用教學

這份文件用來練習 Terraform、Ansible、Prometheus 和 Grafana 的基本工作流。

你可以用兩種模式操作：

- Docker Target Mode：不用 server，直接在本機用 Docker 模擬新增、刪除、編輯和派送資源
- Server Agent Mode：預設用 mock inventory 練習流程，也可以打開 AWS EC2 模式建立真的 Linux server，再用 Ansible 部署 monitoring stack

建議先從 Docker Target Mode 開始，因為它最容易重複練習，也最適合展示 IaC 流程。

## 開始前確認位置

以下指令都假設你在專案根目錄執行，也就是看得到 `infra/`、`ansible/`、`agent/`、`docs/` 的那一層。

如果你的終端機目前在外層資料夾，請先進入專案：

```bash
cd iac-monitoring-system
```

確認位置：

```bash
ls
```

應該會看到：

```text
ansible  agent  docs  infra
```

這個專案有兩個 Terraform 目錄：

```text
infra/docker/terraform/  Docker Target Mode，會建立本機 Docker app containers
infra/server/terraform/      Server Agent Mode，預設產生 mock inventory，可選擇建立 AWS EC2
```

## 你會練到什麼

- Terraform 管理 desired state
- Terraform 建立、刪除、修改資源
- Terraform 產生 Ansible inventory 和 variables
- Ansible 根據 Terraform output 派送設定
- Prometheus scrape targets
- Grafana 自動載入 datasource 和 dashboard
- 用 UI 驗證資源狀態是否符合預期

## Docker Target Mode

Docker 模式會用 Terraform 建立幾個 HTTP app containers，再把 target 清單寫給 central Prometheus/Grafana stack。

架構：

```text
Terraform -> Docker app containers
          -> monitoring stack vars

Ansible   -> central Prometheus/Grafana
          -> blackbox exporter
```

### 啟動 Docker Target

```bash
cd infra/docker/terraform
terraform init
terraform apply

cd ../../..
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

也可以用 Makefile 快速啟動：

```bash
make docker-up ANSIBLE_FLAGS="--ask-become-pass"
```

開啟服務：

```text
App node 1:  http://localhost:18080
App node 2:  http://localhost:18081
Prometheus:  http://localhost:9090
Grafana:     http://localhost:3000
Grafana 帳密: admin / admin
Dashboard:   IaC Docker Target Overview
Details:     IaC Docker Target Details
```

如果 `terraform init` 顯示：

```text
Terraform initialized in an empty directory!
The directory has no Terraform configuration files.
```

代表你目前不在有 `.tf` 檔案的 Terraform 目錄。請回到專案根目錄後重新進入正確資料夾：

```bash
cd /home/ianhsu/Projects/iac-monitoring-system/iac-monitoring-system
cd infra/docker/terraform
ls *.tf
terraform init
```

### 查看目前 Terraform 管理的資源

```bash
cd infra/docker/terraform
terraform state list
terraform output
```

也可以用 Docker 直接看：

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
```

### 模擬新增資源

把 app container 從 2 個增加到 3 個：

```bash
cd infra/docker/terraform
terraform apply -var='node_count=3'

cd ../../..
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

Makefile 版本：

```bash
make docker-scale NODE_COUNT=3 ANSIBLE_FLAGS="--ask-become-pass"
```

驗證：

```bash
curl http://localhost:18082
```

再打開 Grafana，`Terraform Managed Containers` 應該會變成 3。

如果要看每個 target 的細節，可以切到 `IaC Docker Target Details`，裡面有 failed targets、availability、latency table 和 HTTP status code。

### 模擬刪除資源

把 app container 縮回 1 個：

```bash
cd infra/docker/terraform
terraform apply -var='node_count=1'

cd ../../..
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

Makefile 版本：

```bash
make docker-scale NODE_COUNT=1 ANSIBLE_FLAGS="--ask-become-pass"
```

驗證：

```bash
docker ps --format '{{.Names}}' | grep iac-lab-app-node
```

Grafana 的 target 數量會跟著變少。

### 模擬編輯資源

修改 app container 回應文字：

```bash
cd infra/docker/terraform
terraform apply -var='app_message_prefix=updated by terraform'
```

Makefile 版本：

```bash
make docker-edit ANSIBLE_FLAGS="--ask-become-pass"
```

驗證：

```bash
curl http://localhost:18080
```

這可以用來展示 Terraform 偵測設定變更，並重新建立需要更新的 container。

### 模擬派送設定

當 Terraform 改變 target 清單後，要重新執行 Ansible，讓 Prometheus 設定跟著更新：

```bash
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

可以用這個網址確認 Prometheus targets：

```text
http://localhost:9090/targets
```

### 模擬故障

手動停止其中一個 Terraform 管理的 app container：

```bash
docker stop iac-lab-app-node-01
```

幾秒後 Grafana 的 `Simulated App Health` 會顯示該 target down。

切到 `IaC Docker Target Details` 可以看到 `Failed Targets` 變成 1，並確認是哪個 target down。

恢復：

```bash
cd infra/docker/terraform
terraform apply
```

Terraform 會把 container 拉回 desired state。

### 清除 Docker Target

先刪 Terraform 管理的 app containers 和 network：

```bash
cd infra/docker/terraform
terraform destroy
```

再讓 central stack 重新載入設定：

```bash
cd ../../..
rm -f ansible/group_vars/monitoring_stack/docker_targets.yml
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

Makefile 版本：

```bash
make docker-down ANSIBLE_FLAGS="--ask-become-pass"
```

## Server Agent Mode

Server Agent 模式比較接近真實環境。Terraform 預設使用 mock inventory，讓你先練習 Terraform 產生 Ansible inventory 的流程；如果把 `enable_aws_resources` 改成 `true`，Terraform 會透過 AWS provider 建立 EC2、security group 和 key pair，再產生 inventory。Ansible 會把 Python agent 部署到遠端 Linux servers，並在 control node 部署 Prometheus 和 Grafana。

Python agent 會做兩件事：

- 寫 log 到 `/var/log/monitor-agent.log`
- 開啟 Prometheus metrics endpoint：`http://<server IP>:8000/metrics`

### Server Agent 模式的兩種跑法

預設安全模式不會建立 AWS 資源，也不會產生雲端費用：

```text
enable_aws_resources = false
```

這時 Terraform 會使用 `server_hosts` 產生 inventory。你可以把 IP 改成既有 server 或 Linux server 的 IP，也可以只用來展示 Terraform output 和 inventory 流程。

如果要真的建立 AWS EC2，請先準備：

- AWS credentials，例如 `aws configure` 或環境變數
- 可用的 AMI ID
- SSH public/private key
- 合適的 VPC/subnet，或使用 AWS default VPC

### 修改 Server Agent / AWS 設定

編輯：

```text
infra/server/terraform/variables.tf
```

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

> 注意：真的開 AWS 前，建議把 `allowed_ssh_cidr_blocks` 和 `allowed_monitoring_cidr_blocks` 從 `0.0.0.0/0` 改成你的固定 IP，例如 `["203.0.113.10/32"]`。`allowed_monitoring_cidr_blocks` 會影響 Grafana `3000`、Prometheus `9090`、monitor-agent metrics `8000`。

如果是既有 VMware / Linux servers，可以先用類似這樣的 `infra/server/terraform/terraform.tfvars`：

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

`ssh_private_key_file = ""` 代表 inventory 不指定 SSH key。這時 Ansible 可以用互動式密碼登入：

```bash
make server-agent ANSIBLE_FLAGS="--ask-pass --ask-become-pass"
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

正式環境建議改用 SSH key。

### 產生 Inventory

```bash
cd infra/server/terraform
terraform init
terraform apply
```

確認 output：

```bash
terraform output
```

如果要真的建立 AWS EC2，可以用 CLI 變數覆蓋：

```bash
terraform apply \
  -var='enable_aws_resources=true' \
  -var='aws_ami_id=ami-xxxxxxxxxxxxxxxxx' \
  -var='ssh_public_key_file=~/.ssh/id_rsa.pub' \
  -var='ssh_private_key_file=~/.ssh/id_rsa'
```

### 部署到 Linux servers

```bash
cd ../../..
make server-agent ANSIBLE_FLAGS="--ask-pass --ask-become-pass"
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

如果已經設定 SSH key：

```bash
make server-agent
make server-stack ANSIBLE_FLAGS="--ask-become-pass"
```

### Server Agent 模式驗證

Grafana：

```text
http://localhost:3000
admin / admin
Dashboard: IaC Agent Overview
```

Prometheus targets：

```text
http://localhost:9090/targets
Jobs: monitor-agent
```

在 Linux server 上檢查 agent：

```bash
sudo systemctl status monitor-agent
sudo journalctl -u monitor-agent -n 50 --no-pager
sudo tail -f /var/log/monitor-agent.log
curl http://localhost:8000/metrics
```

### 清除 AWS Server Agent Mode

如果你有打開 `enable_aws_resources=true` 建立 EC2，練習完請刪除，避免產生費用：

```bash
cd infra/server/terraform
terraform destroy \
  -var='enable_aws_resources=true' \
  -var='aws_ami_id=ami-xxxxxxxxxxxxxxxxx' \
  -var='ssh_public_key_file=~/.ssh/id_rsa.pub'
```
