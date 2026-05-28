# iac-monitoring-system 學習筆記

這份文件用來幫助理解本專案的操作方式、部署流程，以及它和 Kubernetes、Terraform、Ansible 的關係。重點不是背指令，而是搞清楚「每個元件為什麼存在」。

## 一句話理解

這個專案是一套 hybrid monitoring lab：

- 在 Kubernetes mode 中，用 k3d 建一個本機 Kubernetes cluster，透過 Helm 安裝 kube-prometheus-stack，並部署自製 Python monitor-agent DaemonSet。
- 在 VM mode 中，用 Terraform 產生或整理 Linux 主機清單，再用 Ansible 部署 monitor-agent、node_exporter、Prometheus、Grafana、Alertmanager。
- Hybrid 的意思是同一套監控概念可以同時監控 Kubernetes 裡的 workload，也可以監控外部 Linux VM。

## 哪些是我們寫的，哪些不是

不是我們寫的社群元件：

- Prometheus
- Grafana
- Alertmanager
- Prometheus Operator
- kube-state-metrics
- node-exporter
- kube-prometheus-stack Helm chart

本專案自己寫或整合的部分：

- `agent/agent.py`：自製 Python monitor-agent
- `agent/Dockerfile`：把 monitor-agent 包成 container image
- `k8s/manifests/monitor-agent-daemonset.yaml`：讓 monitor-agent 在 Kubernetes 裡以 DaemonSet 執行
- `k8s/manifests/servicemonitor.yaml`：讓 Prometheus Operator 自動發現 monitor-agent metrics endpoint
- `k8s/manifests/prometheusrule.yaml`：自訂 Prometheus alert rules
- `k8s/helm/values.yaml`：調整 kube-prometheus-stack 的 Helm values
- `scripts/k8s-up.sh`：一鍵建立 k3d cluster、安裝 Helm chart、套用 k8s manifests
- `infra/k8s/terraform/`：用 Terraform 管理 k3d cluster 建立與 Helm release
- `infra/vm/terraform/`：用 Terraform 產生 VM/EC2 目標與 Ansible inventory
- `ansible/vm-deploy.yml`：把 monitor-agent、node_exporter、Prometheus stack 部署到 VM mode
- `ansible/files/grafana/dashboards/`：Grafana dashboard 設定
- `runbooks/`：告警處理 Runbook

## Pod、Node、DaemonSet 的關係

Node 是 Kubernetes 裡承載 workload 的機器。在真實環境它通常是 VM 或實體機；在本專案的 k3d 環境裡，node 是 Docker container 裡跑的 k3s node。

Pod 是 Kubernetes 最小部署單位。你的程式不是直接「跑在 node 上」，而是被包進 container，再由 Kubernetes 排程成 pod，放到某個 node 上執行。

DaemonSet 是一種 Kubernetes workload 類型，用來確保每個符合條件的 node 上都跑一個 pod。監控 agent、log agent、node-exporter 這類「每台機器都要有一份」的東西通常會用 DaemonSet。

在本專案裡：

```text
monitor-agent Python script
  -> 打包成 Docker image: monitor-agent:dev
  -> 由 DaemonSet 管理
  -> 每個 Kubernetes node 上跑一個 monitor-agent pod
  -> Prometheus 透過 ServiceMonitor scrape /metrics
```

所以如果有人問「這個專案是在監控 pod 還是 node？」比較精準的回答是：

> kube-prometheus-stack 提供 Kubernetes cluster 的基礎監控，包含 node、pod、container、workload 狀態；自製 monitor-agent 則以 DaemonSet 方式跑在每個 node 上，補充自訂 CPU/memory/zombie process/DNS/TCP check metrics。

## Kubernetes mode 架構

Kubernetes mode 的主要目標是模擬業界 Kubernetes monitoring stack。

```text
本機 Docker
  -> k3d cluster
      -> monitoring namespace
          -> kube-prometheus-stack
              -> Prometheus
              -> Grafana
              -> Alertmanager
              -> Prometheus Operator
              -> kube-state-metrics
              -> node-exporter DaemonSet
          -> monitor-agent DaemonSet
          -> ServiceMonitor
          -> PrometheusRule
```

### Kubernetes mode 操作流程

最常用流程：

```bash
make build-agent-image
make k8s-up
make k8s-verify
```

這三個 target 背後做的事：

`make build-agent-image`

- 用 `agent/Dockerfile` 建立 `monitor-agent:dev`
- image 內容包含 `agent/agent.py` 和 `agent/config.yml`
- container 啟動後會在 `:8000/metrics` 提供 Prometheus metrics

`make k8s-up`

- 執行 `scripts/k8s-up.sh`
- 建立 k3d cluster，預設名稱是 `iac-monitoring`
- 把 `monitor-agent:dev` import 到 k3d
- 建立 `monitoring` namespace
- 建立空的 `iac-external-targets` Secret，預留給外部 VM scrape target
- 建立 Grafana dashboard ConfigMap
- 用 Helm 安裝 `prometheus-community/kube-prometheus-stack`
- 套用：
  - `k8s/manifests/monitor-agent-daemonset.yaml`
  - `k8s/manifests/servicemonitor.yaml`
  - `k8s/manifests/prometheusrule.yaml`

`make k8s-verify`

- 列出 `monitoring` namespace 的 pods
- 確認 `monitor-agent` DaemonSet rollout 成功
- port-forward Prometheus 到本機 `19090`
- 呼叫 Prometheus API 確認以下 target 是 `up`：
  - `serviceMonitor/monitoring/monitor-agent/0`
  - `serviceMonitor/monitoring/kube-prometheus-stack-prometheus-node-exporter/0`

### Kubernetes mode 主要 URL

預設對外入口：

- Grafana: <http://localhost:3000>
- Prometheus: <http://localhost:9090>
- Alertmanager: <http://localhost:9093>

Grafana 預設帳密：

```text
admin / admin
```

### Kubernetes mode 清除

```bash
make k8s-down
```

這會刪除 k3d cluster。

## monitoring namespace 裡的 pod 在做什麼

你截圖裡看到的 pod 大概會像這樣：

```text
alertmanager-kube-prometheus-stack-alertmanager-0
kube-prometheus-stack-grafana-xxxxxxxxxx-yyyyy
kube-prometheus-stack-kube-state-metrics-xxxxxxxxxx-yyyyy
kube-prometheus-stack-operator-xxxxxxxxxx-yyyyy
kube-prometheus-stack-prometheus-node-exporter-xxxxx
monitor-agent-xxxxx
prometheus-kube-prometheus-stack-prometheus-0
```

各自用途：

| Pod | 來源 | 作用 |
|---|---|---|
| `prometheus-kube-prometheus-stack-prometheus-0` | kube-prometheus-stack | Prometheus server，負責 scrape metrics、儲存時間序列、執行 PromQL、評估 alert rules |
| `kube-prometheus-stack-grafana-*` | kube-prometheus-stack | Grafana UI，用來看 dashboard |
| `alertmanager-kube-prometheus-stack-alertmanager-0` | kube-prometheus-stack | 接收 Prometheus alerts，負責分組、靜音、路由通知 |
| `kube-prometheus-stack-operator-*` | kube-prometheus-stack | Prometheus Operator，負責把 ServiceMonitor、PrometheusRule 等 CRD 轉成 Prometheus 實際設定 |
| `kube-prometheus-stack-kube-state-metrics-*` | kube-prometheus-stack | 把 Kubernetes object 狀態轉成 metrics，例如 pod/deployment/daemonset/node 狀態 |
| `kube-prometheus-stack-prometheus-node-exporter-*` | kube-prometheus-stack | DaemonSet，每個 node 一個 pod，提供 Linux node CPU/memory/disk/network metrics |
| `monitor-agent-*` | 本專案 | 自製 Python monitor-agent DaemonSet，每個 node 一個 pod，提供自訂 metrics 和 DNS/TCP health checks |

注意：

```text
kube-prometheus-stack-grafana-*  3/3
```

這不是 3 個 Grafana pod，而是 1 個 Grafana pod 裡有 3 個 containers ready。

## monitor-agent 做什麼

`agent/agent.py` 是自製 Python script。它做幾件事：

- 收集 CPU 使用率
- 收集 memory 使用率
- 計算 zombie process 數量
- 做 DNS 檢查
- 做 TCP 連線檢查
- 寫 JSON log
- 開 Prometheus metrics endpoint

主要 metrics：

```text
monitor_agent_cpu_percent
monitor_agent_memory_percent
monitor_agent_zombie_process_count
monitor_agent_network_check_success
monitor_agent_network_check_attempts
monitor_agent_network_check_last_run_timestamp_seconds
monitor_agent_network_check_latency_ms
monitor_agent_network_check_failure
```

預設檢查目標在 `agent/config.yml`：

- DNS: `www.github.com`
- TCP: `google.com:443`
- TCP: `1.1.1.1:443`

在 Kubernetes mode 中，monitor-agent 由 `k8s/manifests/monitor-agent-daemonset.yaml` 部署。它會暴露 port `8000`，ServiceMonitor 會讓 Prometheus 自動去抓。

## ServiceMonitor 是什麼

`ServiceMonitor` 不是原生 Kubernetes 物件，而是 Prometheus Operator 提供的 CRD。

它的目的：

> 告訴 Prometheus Operator：「符合這些 label 的 Service，請讓 Prometheus 去 scrape 它的 /metrics。」

本專案的 `k8s/manifests/servicemonitor.yaml` 會找：

```yaml
app.kubernetes.io/name: monitor-agent
```

然後 scrape：

```text
port: metrics
path: /metrics
interval: 30s
```

這就是為什麼你不需要手動改 Prometheus config，Prometheus 也能發現 monitor-agent。

## PrometheusRule 是什麼

`PrometheusRule` 也是 Prometheus Operator 提供的 CRD。

本專案的 `k8s/manifests/prometheusrule.yaml` 定義了幾種 alert：

- `InstanceDown`
- `HighCPUUsage`
- `HighMemoryUsage`
- `DiskAlmostFull`
- `HighLoadAverage`

它們會由 Prometheus 評估，觸發後送給 Alertmanager。

## worker 數量怎麼理解

目前 `scripts/k8s-up.sh` 裡的 k3d 建 cluster 指令是：

```bash
k3d cluster create "$CLUSTER" \
  --port "${GRAFANA_PORT}:3000@loadbalancer" \
  --port "${PROMETHEUS_PORT}:9090@loadbalancer" \
  --port "${ALERTMANAGER_PORT}:9093@loadbalancer" \
  --wait
```

這裡沒有指定 `--agents`。

在 k3d 裡：

- server node 類似 control-plane node
- agent node 類似 worker node
- 沒寫 `--agents` 時，通常會建立 1 個 server node、0 個 agent worker node
- k3d 的 server node 通常仍可排程 workload，所以你會看到 monitor-agent 跑出 1 個 pod

所以目前作品集截圖裡只有一個 `monitor-agent-*` 和一個 `node-exporter-*`，不是因為 DaemonSet 壞掉，而是因為 cluster 只有一個可排程 node。

如果要讓作品集更有說服力，可以把 k3d cluster 改成多 worker，例如：

```bash
k3d cluster create "$CLUSTER" \
  --agents 2 \
  --port "${GRAFANA_PORT}:3000@loadbalancer" \
  --port "${PROMETHEUS_PORT}:9090@loadbalancer" \
  --port "${ALERTMANAGER_PORT}:9093@loadbalancer" \
  --wait
```

這樣會比較容易看到：

```text
monitor-agent                          2/2 或 3/3
kube-prometheus-stack-node-exporter    2/2 或 3/3
```

實際數字取決於 server node 是否也參與排程，以及 DaemonSet 是否有 toleration 可以跑在 server/control-plane node 上。

建議學習時常用這些指令看差異：

```bash
kubectl get nodes -o wide
kubectl -n monitoring get pods -o wide
kubectl -n monitoring get daemonset
kubectl -n monitoring describe daemonset monitor-agent
kubectl -n monitoring describe daemonset kube-prometheus-stack-prometheus-node-exporter
```

## Terraform 在 Kubernetes mode 做什麼

Kubernetes Terraform 目錄是：

```text
infra/k8s/terraform/
```

主要檔案：

- `main.tf`
- `variables.tf`
- `outputs.tf`

它做的事：

- 用 `null_resource` 呼叫 `k3d cluster create`
- 建立 `monitoring` namespace
- 用 Helm provider 安裝 kube-prometheus-stack
- 輸出 Grafana、Prometheus、Alertmanager URL

重要觀念：

> k3d 沒有官方一線 Terraform provider，所以這裡用 Terraform 的 `null_resource` 包裝 k3d CLI。

目前 Kubernetes Terraform mode 主要管理 k3d cluster 與 Helm release；`monitor-agent` DaemonSet、ServiceMonitor、PrometheusRule 在 `scripts/k8s-up.sh` 路線中是由 `kubectl apply` 套用。

Terraform 操作：

```bash
terraform -chdir=infra/k8s/terraform init
terraform -chdir=infra/k8s/terraform apply
terraform -chdir=infra/k8s/terraform destroy
```

預設變數：

| 變數 | 預設 | 意義 |
|---|---:|---|
| `cluster_name` | `iac-monitoring` | k3d cluster 名稱 |
| `chart_version` | `65.0.0` | kube-prometheus-stack chart 版本 |
| `grafana_port` | `3000` | 本機 Grafana port |
| `prometheus_port` | `9090` | 本機 Prometheus port |
| `alertmanager_port` | `9093` | 本機 Alertmanager port |

## VM mode 架構

VM mode 是用來模擬傳統 Linux server 監控。

```text
Terraform
  -> 產生 ansible/inventory.ini
  -> 可選擇使用既有 Linux servers
  -> 或 enable_aws_resources=true 建立 AWS EC2

Ansible
  -> monitoring_agents
      -> 安裝 Python monitor-agent
      -> 安裝 node_exporter
      -> 建立 systemd service
  -> monitoring_stack
      -> 在本機控制節點用 docker compose 跑 Prometheus/Grafana/Alertmanager
      -> Prometheus scrape VM 的 :8000 和 :9100
```

VM mode 裡的 `monitor-agent` 不是跑成 Kubernetes pod，而是跑成 Linux systemd service。

## Terraform 在 VM mode 做什麼

VM Terraform 目錄：

```text
infra/vm/terraform/
```

它有兩種模式：

### 1. Mock / existing Linux server mode

預設：

```hcl
enable_aws_resources = false
```

這時 Terraform 不會真的建立 AWS EC2，而是根據 `server_hosts` 產生：

```text
ansible/inventory.ini
```

用途是讓你用既有 Linux 主機做 lab。

### 2. AWS EC2 mode

當你設定：

```hcl
enable_aws_resources = true
```

Terraform 會建立：

- EC2 instances
- key pair
- security group
- Ansible inventory

相關 port：

| Port | 用途 |
|---:|---|
| `22` | SSH |
| `3000` | Grafana |
| `9090` | Prometheus |
| `9093` | Alertmanager |
| `8000` | monitor-agent metrics |
| `9100` | node_exporter metrics |

VM Terraform 常用指令：

```bash
make vm-plan
make vm-apply
```

AWS 版本：

```bash
cp infra/vm/terraform/terraform.tfvars.aws.example infra/vm/terraform/terraform.tfvars.aws
# 編輯 AMI/VPC/subnet/CIDR
make vm-aws-plan
make vm-aws-apply
make vm-aws-deploy
```

## Ansible 做什麼

主要 playbook：

```text
ansible/vm-deploy.yml
```

它分成兩段：

### Deploy monitoring agent

跑在 inventory group：

```text
monitoring_agents
```

做的事：

- 安裝 Python、pip、venv、logrotate
- 複製 `agent/agent.py`
- 複製 `agent/config.yml`
- 建立 Python virtualenv
- 安裝 `requirements.txt`
- 建立 `/var/log/monitor-agent.log`
- 安裝 logrotate config
- 安裝 systemd service
- enable/start `monitor-agent`
- include `node_exporter` role

### Deploy Prometheus and Grafana stack

跑在 inventory group：

```text
monitoring_stack
```

目前 inventory 預設是：

```text
localhost ansible_connection=local
```

做的事：

- 檢查本機 Docker
- 建立 `/opt/iac-monitoring-stack`
- 部署 Prometheus config
- 部署 alert rules
- 部署 Alertmanager config
- 部署 Grafana datasource/dashboard provisioning
- 部署 docker-compose.yml
- 用 docker compose 跑：
  - Prometheus
  - Grafana
  - Alertmanager

常用指令：

```bash
make vm-agent
make vm-stack
make vm-up
```

## Hybrid monitoring 怎麼串起來

Kubernetes mode 裡，Prometheus 可以透過兩種方式取得 targets：

### 1. Kubernetes 內部 targets

透過 Prometheus Operator 的 CRD：

- ServiceMonitor
- PrometheusRule
- kube-state-metrics
- node-exporter
- kubelet/cAdvisor

### 2. 外部 VM targets

透過：

```text
k8s/user-managed/external-targets-secret.example.yaml
```

這個 Secret 會被 `k8s/helm/values.yaml` 裡的設定讀取：

```yaml
additionalScrapeConfigsSecret:
  enabled: true
  name: iac-external-targets
  key: external-targets.yaml
```

你可以把 VM 的 metrics endpoint 放進去：

```yaml
- job_name: vm-node-exporter
  static_configs:
    - targets:
        - 10.0.1.10:9100
        - 10.0.1.11:9100

- job_name: vm-monitor-agent
  static_configs:
    - targets:
        - 10.0.1.10:8000
        - 10.0.1.11:8000
```

這樣 Kubernetes 裡的 Prometheus 就能同時監控：

- k8s nodes
- k8s pods/workloads
- k8s 裡的 monitor-agent DaemonSet
- 外部 VM 的 node_exporter
- 外部 VM 的 monitor-agent

## 建議學習順序

### 第 1 階段：先懂 Kubernetes mode

```bash
make build-agent-image
make k8s-up
kubectl get nodes -o wide
kubectl -n monitoring get pods -o wide
kubectl -n monitoring get daemonset
kubectl -n monitoring get servicemonitor
kubectl -n monitoring get prometheusrule
make k8s-verify
```

觀察重點：

- k3d 建了幾個 node
- `monitor-agent` 有幾個 pods
- `node-exporter` 有幾個 pods
- Prometheus targets 裡哪些是 up
- Grafana dashboard 是否有資料

### 第 2 階段：理解 DaemonSet

看：

```bash
kubectl -n monitoring describe daemonset monitor-agent
kubectl -n monitoring get pods -l app.kubernetes.io/name=monitor-agent -o wide
```

觀察：

- 每個 pod 被排到哪個 node
- DaemonSet desired/current/ready 數字
- 如果 node 數量改變，pod 數量是否跟著改變

### 第 3 階段：理解 Prometheus Operator

看：

```bash
kubectl -n monitoring get servicemonitor monitor-agent -o yaml
kubectl -n monitoring get prometheusrule linux-node-alerts -o yaml
```

理解：

- ServiceMonitor 是 scrape 設定
- PrometheusRule 是 alert rule 設定
- Operator 會把 CRD 轉成 Prometheus 真正使用的 config

### 第 4 階段：理解 Terraform

Kubernetes Terraform：

```bash
terraform -chdir=infra/k8s/terraform init
terraform -chdir=infra/k8s/terraform plan
```

VM Terraform：

```bash
terraform -chdir=infra/vm/terraform init
terraform -chdir=infra/vm/terraform plan
```

觀察：

- Terraform 管的是 desired state
- Kubernetes mode 管 k3d cluster + Helm release
- VM mode 管 inventory 或 AWS EC2

### 第 5 階段：理解 Ansible

```bash
ansible-playbook -i ansible/inventory.ini ansible/vm-deploy.yml --syntax-check
make vm-up
```

觀察：

- Ansible 是把軟體裝到主機上的工具
- 它適合處理 systemd、檔案、套件、服務啟停
- VM mode 的 monitor-agent 是 systemd service，不是 Kubernetes pod

## 面試或履歷可以怎麼講

中文版本：

> 我做了一個 hybrid monitoring lab。Kubernetes mode 使用 k3d 模擬 Kubernetes cluster，透過 Helm 整合 kube-prometheus-stack，並用 Prometheus Operator 的 ServiceMonitor/PrometheusRule 管理 scrape 與 alert。除此之外，我寫了一個 Python monitor-agent，打包成 container 後用 DaemonSet 部署到每個 node，提供自訂 CPU/memory/zombie process 與 DNS/TCP health check metrics。VM mode 則用 Terraform 產生 inventory 或建立 EC2，再用 Ansible 把同一個 monitor-agent 以 systemd service 部署到 Linux 主機，並搭配 node_exporter、Prometheus、Grafana、Alertmanager 完成傳統 VM 監控。

英文版本：

> Built a hybrid Kubernetes/VM monitoring lab using Terraform, Ansible, Helm, Prometheus, and Grafana. The Kubernetes mode runs kube-prometheus-stack on k3d and extends it with a custom Python monitor-agent deployed as a DaemonSet, discovered through ServiceMonitor, and covered by PrometheusRule alerts. The VM mode uses Terraform to manage target hosts or EC2 instances and Ansible to deploy the same monitor-agent as a systemd service with node_exporter and a Docker Compose based Prometheus/Grafana/Alertmanager stack.

## 常見誤解修正

### kube-prometheus-stack 是我們寫的嗎？

不是。它是社群維護的 Helm chart。本專案是整合它，並在上面加上自製 agent、告警規則、dashboard、VM target discovery。

### monitor-agent 是 pod 還是 node？

monitor-agent 是你寫的 Python script。  
在 Kubernetes mode 中，它被包成 container，並由 DaemonSet 管理，所以實際跑起來會是 pod。  
DaemonSet 的特性是每個符合條件的 node 上跑一個 monitor-agent pod。

### 目前為什麼只有一個 monitor-agent pod？

因為目前 k3d cluster 建立時沒有指定 `--agents`，所以通常只有一個可排程 node。DaemonSet 沒壞，只是 node 數量少。

### 這個專案有監控 pod 嗎？

有，但主要是 kube-prometheus-stack 內的 kube-state-metrics、kubelet/cAdvisor、Prometheus Operator 生態提供 pod/workload/container 監控。  
自製 monitor-agent 比較偏 node/host 層級與自訂網路健康檢查。

### Terraform 和 Ansible 差在哪？

在本專案裡：

- Terraform：決定基礎設施長什麼樣，例如 k3d cluster、Helm release、EC2、inventory。
- Ansible：把軟體裝到機器上並啟動服務，例如 systemd monitor-agent、node_exporter、docker-compose Prometheus stack。

## 快速查表

| 想看什麼 | 指令 |
|---|---|
| cluster nodes | `kubectl get nodes -o wide` |
| monitoring pods | `kubectl -n monitoring get pods -o wide` |
| DaemonSet 狀態 | `kubectl -n monitoring get daemonset` |
| monitor-agent pods | `kubectl -n monitoring get pods -l app.kubernetes.io/name=monitor-agent -o wide` |
| ServiceMonitor | `kubectl -n monitoring get servicemonitor` |
| PrometheusRule | `kubectl -n monitoring get prometheusrule` |
| Prometheus targets | `make k8s-verify` |
| 建 agent image | `make build-agent-image` |
| 啟動 k8s lab | `make k8s-up` |
| 刪除 k8s lab | `make k8s-down` |
| VM Terraform plan | `make vm-plan` |
| VM Ansible deploy | `make vm-up` |
| 驗證 VM stack | `make vm-smoke` (深度) / `make vm-quickcheck` (HTTP only) |
