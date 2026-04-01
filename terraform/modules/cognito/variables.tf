variable "env" { type = string }
variable "app_name" {
  type    = string
  default = "ticketing"
}
variable "cognito_domain_prefix" { type = string }
