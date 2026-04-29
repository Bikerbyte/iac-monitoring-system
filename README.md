# iac-monitoring-agent

這是一個輕量級 Infrastructure as Code 教學專案，用來示範 DevOps / SRE 常見流程：先用 Terraform 管理基礎設施資訊，再用 Ansible 佈署 Python monitoring agent，最後交給 systemd 長期執行並寫入 log。

這份 lab 目前採用 local lab mode：Terraform 會產生 Ansible inventory，讓你可以先拿既有 Linux VM 練習完整 IaC 流程。之後要換成 VMware、vSphere、Proxmox 或 cloud provider 時，只要替換 Terraform resource，保留 output 與 inventory 介面即可。

## Architecture

```text
Terraform -> Ansible -> Python Agent -> /var/log/monitor-agent.log
```

- Terraform：管理節點清單、網段資訊，輸出 VM IP，並產生 `ansible/inventory.ini`
- Ansible：安裝 Python 套件、複製 agent/config/service，啟用 systemd
- Python Agent：檢查 CPU、memory、zombie process、DNS、TCP connectivity
- systemd：開機自動啟動，失敗時自動重啟
- Python venv：agent dependencies 安裝在 `/opt/monitor-agent/venv`，避免污染系統 Python

## Features

- Automated provisioning interface：Terraform 統一維護 lab 節點資料與輸出
- Configuration management：Ansible 重複佈署不會破壞既有狀態
- Monitoring & diagnostics：CPU、memory、zombie process、DNS、TCP check
- Failure classification：DNS resolution error、TCP timeout、connection refused、generic socket error
- Logging：使用 Python logging 寫入 `/var/log/monitor-agent.log`
- Bonus：YAML config、network retry、CLI override、systemd restart

## Repository Structure

```text
terraform/
  main.tf
  variables.tf
  outputs.tf
ansible/
  playbook.yml
  roles/
agent/
  agent.py
  config.yml
systemd/
  monitor-agent.service
requirements.txt
README.md
```

## Prerequisites

- 1 到 2 台可 SSH 登入的 Linux VM
- Terraform >= 1.5
- Ansible
- Linux VM 上的 sudo 權限

先修改 [terraform/variables.tf](terraform/variables.tf) 裡的 `vm_hosts`，填入你的 VM IP、登入帳號和 SSH key。

## Usage

初始化 Terraform：

```bash
cd terraform
terraform init
terraform apply
```

確認 Terraform output：

```bash
terraform output vm_ip_addresses
terraform output ansible_inventory_path
```

用 Ansible 佈署 agent：

```bash
cd ..
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
```

在 Linux VM 上檢查服務：

```bash
sudo systemctl status monitor-agent
sudo journalctl -u monitor-agent -n 50 --no-pager
sudo tail -f /var/log/monitor-agent.log
```

本機開發時也可以只跑一次 agent：

```bash
python agent/agent.py --config agent/config.yml --log-file ./monitor-agent.log --once
```

## Agent Config

[agent/config.yml](agent/config.yml) 集中管理檢查週期、retry、log file 與 network target。

預設檢查：

- DNS：`www.graid.com`
- TCP internal：`192.168.1.254:443`
- TCP external：`google.com:443`

## Design Considerations

- Lightweight agent：只做必要檢查，避免引入大型監控框架
- Separation of concerns：Terraform 管節點、Ansible 管佈署、systemd 管生命週期
- Repeatability：同一份 playbook 可以重跑，方便修正設定或更新 agent
- 維運可追：log 訊息保留 check type、target、attempts 與錯誤分類

## Future Improvements

- Prometheus exporter 或 pushgateway integration
- Centralized logging，例如 Loki、ELK 或 OpenSearch
- Alerting system，例如 Alertmanager、Teams webhook、Slack webhook
- CI/CD integration，自動檢查 Terraform format、Ansible syntax 與 Python lint
- Terraform provider 換成 VMware / vSphere / Proxmox / cloud，真正建立 VM
