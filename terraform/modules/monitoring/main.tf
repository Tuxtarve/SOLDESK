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
    alb_dns           = var.alb_dns
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
# destroy/apply 사이클에서 데이터 보존 책임은 scripts/destroy.sh가 짐:
#   1) destroy 시작 시 state에서 EBS와 attachment를 분리
#   2) terraform destroy는 state에 없는 리소스를 건드리지 않음
#   3) AWS 상의 EBS 볼륨은 그대로 남음 → 다음 setup-all.sh가 import해서 재사용
# prevent_destroy lifecycle은 의도적으로 두지 않는다. 이전에 prevent_destroy=true
# 였을 때, destroy.sh를 거치지 않고 직접 terraform destroy를 호출하면 plan 단계
# 에서 fail해 사이클 자체가 막히는 데드락이 발생했음. 보호 책임을 destroy.sh
# 한 곳에 일원화한다.
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
}

resource "aws_volume_attachment" "monitoring_data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.monitoring_data.id
  instance_id                    = aws_instance.monitoring.id
  force_detach                   = true
  stop_instance_before_detaching = false
}
