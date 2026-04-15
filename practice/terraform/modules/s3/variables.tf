# modules/s3/variables.tf

variable "bucket_name" {
  description = "생성할 S3 버킷의 고유 이름"
  type        = string
}

variable "cloudfront_distribution_arn" {
  description = "S3 버킷 정책에 추가할 CloudFront 배포의 ARN"
  type        = string
}
