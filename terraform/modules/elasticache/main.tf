resource "aws_elasticache_subnet_group" "main" {
  name       = "ticketing-redis-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "ticketing-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [var.security_group_id]

  # 스냅샷 비활성화 (프리티어 최적화)
  snapshot_retention_limit = 0

  tags = { Name = "ticketing-redis", Environment = var.env }
}
