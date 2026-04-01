variable "env" { type = string }

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
