variable "env" { type = string }
variable "frontend_bucket_id" { type = string }
variable "frontend_bucket_arn" { type = string }
variable "frontend_domain" { type = string }
variable "waf_acl_arn" { type = string }
variable "alb_dns_name" {
  description = "ALB DNS name for API origin. 빈 문자열이면 API origin이 생성되지 않습니다."
  type        = string
  default     = ""
}
