data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  key_name               = var.key_name

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    prometheus_version   = "2.51.0"
    grafana_version      = "10.4.0"
    alertmanager_version = "0.27.0"
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "Ticketing-Monitoring-Host", Environment = var.env, Layer = "web" }
}
