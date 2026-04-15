# 1. CloudFront가 S3에 접근할 수 있게 해주는 '신분증' (OAC)
resource "aws_cloudfront_origin_access_control" "default" {
  name                              = "s3-oac-setup"
  description                       = "CloudFront Access to S3"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 2. 실제 CloudFront 배포 설정
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = var.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  # [추가] 모니터링: 접속 로그 설정
  logging_config {
    include_cookies = false
    bucket          = var.log_bucket_domain_name # 로그 전용 버킷의 도메인 (variables.tf에 추가 필요)
    prefix          = "cf-access-logs/"
  }

  # [추가] 장애 대응: 404 에러 시 예쁜 에러 페이지 보여주기
  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/error.html"
    error_caching_min_ttl = 300
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Origin"

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600  
    max_ttl                = 86400

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  restrictions {
    # [변경] 보안 강화: 한국(KR) 사용자만 접속 허용
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["KR"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}