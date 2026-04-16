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

# cognito <-> cloudfront <-> api_gateway 순환 참조를 끊기 위해 root-level 변수로 관리.
# 첫 apply: 빈 문자열 → cognito는 http://localhost placeholder URL 사용
# setup-all.sh가 첫 apply 후 cloudfront_domain을 tfvars에 박고 재apply하면
# 실제 CloudFront 도메인으로 callback/logout URL이 갱신된다.
variable "frontend_callback_domain" {
  description = "Cognito 콜백/로그아웃 URL 생성용 프론트엔드 도메인 (CloudFront). setup-all.sh가 자동 주입."
  type        = string
  default     = ""
}

variable "cognito_domain_prefix" {
  description = "Cognito 호스티드 UI 도메인 접두사 (전역 유일)"
  type        = string
  default     = "ticketing-auth-734772"
}
