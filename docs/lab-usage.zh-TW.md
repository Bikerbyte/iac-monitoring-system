# IaC Monitoring Lab 使用教學

這份 lab 用來練習 Terraform、Ansible、Prometheus 和 Grafana 的基本工作流。

你可以用兩種模式操作：

- Docker simulation mode：不用 VM，直接在本機用 Docker 模擬新增、刪除、編輯和派送資源
- VM lab mode：使用真的 Linux VM，由 Terraform 產生 inventory，再用 Ansible 部署 monitoring stack

建議先從 Docker simulation mode 開始，因為它最容易重複練習，也最適合展示 IaC 流程。

## 開始前確認位置

以下指令都假設你在專案根目錄執行，也就是看得到 `docker-lab/`、`terraform/`、`ansible/` 的那一層。

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
ansible  docker-lab  terraform  docs
```

## 你會練到什麼

- Terraform 管理 desired state
- Terraform 建立、刪除、修改資源
- Terraform 產生 Ansible inventory 和 variables
- Ansible 根據 Terraform output 派送設定
- Prometheus scrape targets
- Grafana 自動載入 datasource 和 dashboard
- 用 UI 驗證資源狀態是否符合預期

## Docker Simulation Mode

Docker 模式會用 Terraform 建立幾個 HTTP app containers，再用 Ansible 部署 blackbox exporter、Prometheus 和 Grafana。

架構：

```text
Terraform -> Docker app containers
          -> Ansible inventory/group vars

Ansible   -> blackbox exporter
          -> Prometheus
          -> Grafana dashboard
```

### 啟動 Docker Lab

```bash
cd docker-lab/terraform
terraform init
terraform apply

cd ../..
ansible-playbook -i ansible/docker-lab-inventory.ini ansible/docker-lab.yml
```

開啟服務：

```text
App node 1:  http://localhost:18080
App node 2:  http://localhost:18081
Prometheus:  http://localhost:19090
Grafana:     http://localhost:13000
Grafana 帳密: admin / admin
Dashboard:   IaC Docker Lab Overview
```

如果 `terraform init` 顯示：

```text
Terraform initialized in an empty directory!
The directory has no Terraform configuration files.
```

代表你目前不在有 `.tf` 檔案的 Terraform 目錄。請回到專案根目錄後重新進入正確資料夾：

```bash
cd /home/ianhsu/Projects/iac-monitoring-system/iac-monitoring-system
cd docker-lab/terraform
ls *.tf
terraform init
```

### 查看目前 Terraform 管理的資源

```bash
cd docker-lab/terraform
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
cd docker-lab/terraform
terraform apply -var='node_count=3'

cd ../..
ansible-playbook -i ansible/docker-lab-inventory.ini ansible/docker-lab.yml
```

驗證：

```bash
curl http://localhost:18082
```

再打開 Grafana，`Terraform Managed Containers` 應該會變成 3。

### 模擬刪除資源

把 app container 縮回 1 個：

```bash
cd docker-lab/terraform
terraform apply -var='node_count=1'

cd ../..
ansible-playbook -i ansible/docker-lab-inventory.ini ansible/docker-lab.yml
```

驗證：

```bash
docker ps --format '{{.Names}}' | grep iac-lab-app-node
```

Grafana 的 target 數量會跟著變少。

### 模擬編輯資源

修改 app container 回應文字：

```bash
cd docker-lab/terraform
terraform apply -var='app_message_prefix=updated by terraform'
```

驗證：

```bash
curl http://localhost:18080
```

這可以用來展示 Terraform 偵測設定變更，並重新建立需要更新的 container。

### 模擬派送設定

當 Terraform 改變 target 清單後，要重新執行 Ansible，讓 Prometheus 設定跟著更新：

```bash
ansible-playbook -i ansible/docker-lab-inventory.ini ansible/docker-lab.yml
```

可以用這個網址確認 Prometheus targets：

```text
http://localhost:19090/targets
```

### 模擬故障

手動停止其中一個 Terraform 管理的 app container：

```bash
docker stop iac-lab-app-node-01
```

幾秒後 Grafana 的 `Simulated App Health` 會顯示該 target down。

恢復：

```bash
cd docker-lab/terraform
terraform apply
```

Terraform 會把 container 拉回 desired state。

### 清除 Docker Lab

先刪 Terraform 管理的 app containers 和 network：

```bash
cd docker-lab/terraform
terraform destroy
```

再清掉 Ansible 啟動的 monitoring containers：

```bash
docker rm -f iac-lab-blackbox iac-lab-prometheus iac-lab-grafana
```

## VM Lab Mode

VM 模式比較接近真實環境。Terraform 不直接建立 VM，而是管理 VM 清單並產生 Ansible inventory；Ansible 再把 agent、node_exporter、Prometheus 和 Grafana 部署到 Linux VM。

### 修改 VM 清單

編輯：

```text
terraform/variables.tf
```

調整這些欄位：

- `node_count`
- `vm_hosts[*].ip_address`
- `vm_hosts[*].ansible_user`
- `vm_hosts[*].ssh_private_key_file`

### 產生 Inventory

```bash
cd terraform
terraform init
terraform apply
```

確認 output：

```bash
terraform output
```

### 部署到 VM

```bash
cd ..
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
```

### VM 模式驗證

Grafana：

```text
http://<第一台 VM IP>:3000
admin / admin
```

Prometheus targets：

```text
http://<第一台 VM IP>:9090/targets
```

在 VM 上檢查 agent：

```bash
sudo systemctl status monitor-agent
sudo journalctl -u monitor-agent -n 50 --no-pager
sudo tail -f /var/log/monitor-agent.log
sudo docker ps
```

## Demo 建議流程

如果要展示給面試官、同事或課程作業，可以照這個順序：

1. 說明 Terraform 負責資源 desired state
2. 執行 Docker lab `terraform apply`
3. 展示 Terraform 建立 app containers 和產生 Ansible files
4. 執行 Ansible playbook
5. 打開 Prometheus `/targets`
6. 打開 Grafana dashboard
7. 用 `terraform apply -var='node_count=3'` 新增資源
8. 重新執行 Ansible 派送 Prometheus 設定
9. 回 Grafana 看 container 數量變化
10. 用 `docker stop` 模擬故障，再看 Grafana target down

這樣就能完整證明你理解 IaC 的核心流程：宣告狀態、套用變更、派送設定、監控驗證、故障排查。
