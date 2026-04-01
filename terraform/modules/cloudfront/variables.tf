variable "env" { type = string }
variable "frontend_bucket_id" { type = string }
variable "frontend_bucket_arn" { type = string }
variable "frontend_domain" { type = string }
variable "waf_acl_arn" { type = string }
variable "cognito_user_pool_id" { type = string }
variable "cognito_client_id" { type = string }
variable "cognito_domain" { type = string }
variable "alb_dns_name" {
  type    = string
  default = "placeholder.ap-northeast-2.elb.amazonaws.com"
}
