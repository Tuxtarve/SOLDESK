locals {
  account = var.aws_account
}

# 버킷 1: 프론트엔드 SPA
resource "aws_s3_bucket" "frontend" {
  bucket        = "ticketing-frontend-${local.account}"
  force_destroy = true
  tags          = { Name = "ticketing-frontend", Environment = var.env, Purpose = "frontend" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버킷 2: 이벤트 이미지/에셋
resource "aws_s3_bucket" "assets" {
  bucket        = "ticketing-assets-${local.account}"
  force_destroy = true
  tags          = { Name = "ticketing-assets", Environment = var.env, Purpose = "assets" }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버킷 3: 티켓 PDF + 정산 리포트
resource "aws_s3_bucket" "tickets" {
  bucket        = "ticketing-tickets-${local.account}"
  force_destroy = true
  tags          = { Name = "ticketing-tickets", Environment = var.env, Purpose = "tickets" }
}

resource "aws_s3_bucket_versioning" "tickets" {
  bucket = aws_s3_bucket.tickets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "tickets" {
  bucket                  = aws_s3_bucket.tickets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 수명주기: 7년 후 Glacier 이전
resource "aws_s3_bucket_lifecycle_configuration" "tickets" {
  bucket = aws_s3_bucket.tickets.id
  rule {
    id     = "archive-to-glacier"
    status = "Enabled"
    transition {
      days          = 2555 # 7년
      storage_class = "GLACIER"
    }
    filter { prefix = "tickets/" }
  }
}
