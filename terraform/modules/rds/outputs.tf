output "writer_endpoint" {
  value     = aws_db_instance.writer.address
  sensitive = true
}
output "reader_endpoint" {
  value     = aws_db_instance.reader.address
  sensitive = true
}
output "db_port" {
  value = aws_db_instance.writer.port
}
output "proxy_endpoint" {
  description = "RDS Proxy 엔드포인트 (앱은 이 주소로 writer 접근)"
  value       = aws_db_proxy.writer.endpoint
  sensitive   = true
}
