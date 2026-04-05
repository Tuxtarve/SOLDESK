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

variable "alb_dns_name" {
  description = "ALB Ingress Controller가 생성한 ALB의 DNS 이름. EKS 배포 후 'kubectl get ingress -n ticketing'으로 확인"
  type        = string
  default     = ""
}

variable "cognito_domain_prefix" {
  description = "Cognito 호스티드 UI 도메인 접두사 (전역 유일)"
  type        = string
  default     = "ticketing-auth"
}
