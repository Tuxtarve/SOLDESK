output "public_ip" { value = aws_eip.monitoring.public_ip }
output "instance_id" { value = aws_instance.monitoring.id }
