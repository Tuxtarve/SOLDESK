variable "cluster_name" {
  description = "EKS 클러스터의 이름입니다."
  type        = string
}

# 로드밸런서가 배치될 서브넷 정보나 보안 그룹 정보가 필요할 수 있단다.
variable "vpc_id" {
  description = "EKS가 배포된 VPC ID입니다."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS 클러스터의 API 서버 엔드포인트입니다."
  type        = string
}

variable "cluster_ca_certificate" {
  description = "EKS 클러스터의 CA 인증서 데이터입니다."
  type        = string
}