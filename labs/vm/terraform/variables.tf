variable "node_count" {
  description = "Number of Linux nodes to manage in this lab. Keep this between 1 and 2 for the learning scenario."
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 2
    error_message = "node_count must be 1 or 2."
  }
}

variable "enable_aws_resources" {
  description = "When false, Terraform only simulates AWS VM outputs and generates Ansible inventory. When true, Terraform creates EC2 resources."
  type        = bool
  default     = false
}

variable "mock_vm_hosts" {
  description = "Mock Linux hosts used when enable_aws_resources is false. Replace these with reachable VM IPs if you want to run Ansible without AWS."
  type = list(object({
    name                 = string
    ip_address           = string
    ansible_user         = string
    ssh_private_key_file = string
  }))

  default = [
    {
      name                 = "monitor-node-01"
      ip_address           = "192.168.1.101"
      ansible_user         = "ubuntu"
      ssh_private_key_file = "~/.ssh/id_rsa"
    },
    {
      name                 = "monitor-node-02"
      ip_address           = "192.168.1.102"
      ansible_user         = "ubuntu"
      ssh_private_key_file = "~/.ssh/id_rsa"
    }
  ]
}

variable "ansible_user" {
  description = "SSH user for EC2 instances created by this lab. Ubuntu AMIs usually use ubuntu; Amazon Linux usually uses ec2-user."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_file" {
  description = "Private key path written into the generated Ansible inventory."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "ssh_public_key_file" {
  description = "Public key path uploaded to AWS as an EC2 key pair when enable_aws_resources is true."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "aws_region" {
  description = "AWS region for the VM lab."
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_ami_id" {
  description = "AMI ID for EC2 instances. Set this before enabling real AWS resources."
  type        = string
  default     = "ami-0123456789abcdef0"
}

variable "aws_instance_type" {
  description = "EC2 instance type for monitoring lab nodes."
  type        = string
  default     = "t3.micro"
}

variable "aws_instance_name_prefix" {
  description = "Name prefix for EC2 monitoring nodes."
  type        = string
  default     = "iac-monitor-node"
}

variable "aws_key_pair_name" {
  description = "EC2 key pair name managed by Terraform."
  type        = string
  default     = "iac-monitoring-lab-key"
}

variable "aws_security_group_name" {
  description = "Security group name for the AWS VM lab."
  type        = string
  default     = "iac-monitoring-lab-sg"
}

variable "aws_vpc_id" {
  description = "VPC ID for the security group. Leave null to use the default provider behavior."
  type        = string
  default     = null
}

variable "aws_subnet_id" {
  description = "Subnet ID for EC2 instances. Leave null to use the default provider behavior."
  type        = string
  default     = null
}

variable "aws_root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "allowed_ssh_cidr_blocks" {
  description = "CIDR blocks allowed to SSH into EC2 instances."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_monitoring_cidr_blocks" {
  description = "CIDR blocks allowed to access Grafana, Prometheus, and node_exporter."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
