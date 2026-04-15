variable "bucket_regional_domain_name" {
  description = "S3 원본 버킷의 리전별 도메인 주소 (콘텐츠가 들어있는 곳)"
  type        = string
}

# [업그레이드] 로그 수집을 위한 변수 추가
variable "log_bucket_domain_name" {
  description = "CloudFront 접속 로그(.gz)를 저장할 S3 버킷의 도메인 이름"
  type        = string
}

variable "distribution_arn" {
  description = "CloudFront 배포의 ARN (S3 정책 연결 시 필요)"
  type        = string
  default     = ""
}