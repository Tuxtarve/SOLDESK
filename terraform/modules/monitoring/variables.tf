variable "env" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "key_name" {
  type    = string
  default = ""
}
variable "redis_host" {
  type        = string
  description = "ElastiCache Redis endpoint for redis-exporter"
}
