resource "aws_db_subnet_group" "main" {
  name       = "prod-rds-subnet-group"
  subnet_ids = var.subnet_ids
  tags       = { Name = "prod-rds-subnet-group", Environment = var.env }
}

# Primary (Writer) - db.t3.micro MySQL
resource "aws_db_instance" "writer" {
  identifier        = "prod-ticketing-writer"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "ticketing"
  username = "root"
  password = var.db_password
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]

  multi_az                = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = { Name = "ticketing-mysql-writer", Role = "primary", Environment = var.env }
}

# Read Replica (Reader) - db.t3.micro
resource "aws_db_instance" "reader" {
  identifier          = "prod-ticketing-reader"
  replicate_source_db = aws_db_instance.writer.identifier
  instance_class      = "db.t3.micro"

  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "ticketing-mysql-reader", Role = "replica", Environment = var.env }
}

# ── RDS Proxy ──────────────────────────────────────────────────────
# Writer 앞단에 커넥션 풀러 배치 → 백엔드 커넥션 80% 절감, failover 가속
# Multi-AZ Writer + Proxy 조합으로 failover 시간을 60~120초 → 몇 초로 단축
# Reader는 Proxy 없이 직접 접근 (앱 풀 사이즈 축소로 충분)

# DB 자격증명 (RDS Proxy auth에 필수 — Secrets Manager에서 관리)
# recovery_window_in_days=0 → destroy 즉시 제거, 다음 apply에서 같은 이름 재사용 가능
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "ticketing/db-credentials"
  recovery_window_in_days = 0

  tags = { Name = "ticketing-db-credentials", Environment = var.env }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "root"
    password = var.db_password
  })
}

# RDS Proxy가 Secrets Manager에서 자격증명을 읽기 위한 IAM Role
data "aws_iam_policy_document" "rds_proxy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_proxy" {
  name               = "ticketing-rds-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.rds_proxy_assume.json
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "ticketing-rds-proxy-secrets-policy"
  role = aws_iam_role.rds_proxy.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = aws_secretsmanager_secret.db_credentials.arn
    }]
  })
}

# RDS Proxy 본체 — Writer 전용
resource "aws_db_proxy" "writer" {
  name                   = "ticketing-rds-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = var.subnet_ids
  vpc_security_group_ids = [var.security_group_id]
  require_tls            = false
  idle_client_timeout    = 1800
  debug_logging          = false

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.db_credentials.arn
    iam_auth    = "DISABLED"
  }

  tags = { Name = "ticketing-rds-proxy", Environment = var.env }
}

# 커넥션 풀 정책
# max_connections_percent: RDS의 max_connections(t3.micro≈85) 중 75% = ~63개를 Proxy가 점유
# Proxy는 이 63개 백엔드 커넥션을 EKS pod 수십 개에 재사용시킴
resource "aws_db_proxy_default_target_group" "writer" {
  db_proxy_name = aws_db_proxy.writer.name

  connection_pool_config {
    max_connections_percent      = 75
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

# Writer 인스턴스를 Proxy에 등록
resource "aws_db_proxy_target" "writer" {
  db_proxy_name          = aws_db_proxy.writer.name
  target_group_name      = aws_db_proxy_default_target_group.writer.name
  db_instance_identifier = aws_db_instance.writer.id
}
