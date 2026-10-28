variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "cluster_name" {
  type    = string
  default = "ecom-eks"
}

variable "key_name" {
  description = "Name of the EC2 key pair used for the ELK server"
  type        = string
  default     = "my-newkey"
}

variable "my_ip_cidr" {
  description = "Your laptop public IP, for example 49.36.1.2/32 (SSH and Kibana access)"
  type        = string
}

variable "node_type" {
  description = "Worker node instance type"
  type        = string
  default     = "m7i-flex.large"
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "elk_type" {
  description = "ELK server instance type"
  type        = string
  default     = "c7i-flex.large"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
