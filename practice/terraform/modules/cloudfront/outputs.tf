# modules/cloudfront/outputs.tf

output "distribution_arn" {
  description = "S3 버킷 정책에서 참조할 CloudFront 배포의 ARN"
  value       = aws_cloudfront_distribution.s3_distribution.arn
}

output "domain_name" {
  description = "웹사이트 접속에 사용할 CloudFront 도메인 주소"
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}
