variable "env" {
  description = "배포 환경 (dev, prod)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "app_name" {
  description = "애플리케이션 이름"
  type        = string
  default     = "ticketing"
}

variable "db_password" {
  description = "RDS 마스터 비밀번호"
  type        = string
  sensitive   = true
}

variable "key_name" {
  description = "EC2 모니터링 서버 SSH 키페어 이름"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub 리포지토리 (owner/repo)"
  type        = string
  default     = "your-org/ticketing"
}

variable "eks_cluster_name" {
  description = "EKS 클러스터 이름. 서브넷 태그 kubernetes.io/cluster/<이 값> 과 동일해야 합니다. 변경 시 클러스터가 재생성될 수 있습니다."
  type        = string
  default     = "ticketing-eks"
}

variable "alb_listener_arn" {
  description = "Internal ALB의 HTTP listener ARN. ALB Ingress Controller가 생성한 후 setup-all.sh가 자동으로 tfvars에 박는다. API Gateway VPC Link Integration의 target."
  type        = string
  default     = ""
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for Alertmanager"
  type        = string
  default     = ""
  sensitive   = true
}

variable "cognito_domain_prefix" {
  description = "Cognito 호스티드 UI 도메인 접두사 (전역 유일)"
  type        = string
  default     = "ticketing-auth-734772"
}
