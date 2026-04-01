variable "env" { type = string }
variable "aws_region" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "cluster_name" {
  type        = string
  description = "EKS cluster resource name"
}
