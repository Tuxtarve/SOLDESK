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
variable "slack_webhook_url" {
  type        = string
  description = "Slack Incoming Webhook URL for Alertmanager"
  default     = ""
  sensitive   = true
}
variable "alb_dns" {
  type        = string
  description = "Internal ALB DNS for scraping reserv/event/worker metrics"
  default     = ""
}
