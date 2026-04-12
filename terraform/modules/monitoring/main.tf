data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# SSM + CloudWatch 접근용 IAM 역할
resource "aws_iam_role" "monitoring" {
  name = "ticketing-monitoring-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_read" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "ticketing-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name
  key_name               = var.key_name != "" ? var.key_name : null

  user_data_base64 = base64gzip(templatefile("${path.module}/userdata.sh", {
    redis_host        = var.redis_host
    slack_webhook_url = var.slack_webhook_url
  }))

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "Ticketing-Monitoring-Host", Environment = var.env, Layer = "web" }
}

resource "aws_eip" "monitoring" {
  instance = aws_instance.monitoring.id
  domain   = "vpc"
  tags     = { Name = "ticketing-monitoring-eip", Environment = var.env }
}

# ── 영구 데이터 EBS 볼륨 ─────────────────────────────────────────
# Prometheus tsdb / Grafana SQLite / Loki chunks 보관용
# destroy/apply 사이클을 돌려도 데이터를 보존하기 위해 EC2 root와 분리
# prevent_destroy로 실수 삭제 방지 — 평소 destroy는 scripts/destroy.sh가
# 자동으로 state에서 분리한 뒤 지우므로 EBS 자체는 AWS에 그대로 남는다
resource "aws_ebs_volume" "monitoring_data" {
  availability_zone = aws_instance.monitoring.availability_zone
  size              = 50
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "ticketing-monitoring-data"
    Environment = var.env
    Persistent  = "true"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "monitoring_data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.monitoring_data.id
  instance_id                    = aws_instance.monitoring.id
  force_detach                   = true
  stop_instance_before_detaching = false
}
