#!/bin/bash
set -e

yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Docker Compose 설치
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# ── 디렉터리 생성 ──
mkdir -p /opt/monitoring/{prometheus/rules,alertmanager,cloudwatch,grafana/provisioning/datasources,grafana/provisioning/dashboards,grafana/dashboards}
cd /opt/monitoring

# ── docker-compose.yml ──
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:v2.51.0
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
      - '--web.enable-lifecycle'
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:10.4.0
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=root
      - GF_SECURITY_ADMIN_PASSWORD=admin1234
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://%(domain)s:3000/
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
    depends_on:
      - prometheus
    networks:
      - monitoring

  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: alertmanager
    restart: unless-stopped
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--storage.path=/alertmanager'
    networks:
      - monitoring

  cloudwatch-exporter:
    image: prom/cloudwatch-exporter:latest
    container_name: cloudwatch-exporter
    restart: unless-stopped
    ports:
      - "9106:9106"
    volumes:
      - ./cloudwatch/config.yml:/config/config.yml:ro
    environment:
      - AWS_REGION=ap-northeast-2
    networks:
      - monitoring

  redis-exporter:
    image: oliver006/redis_exporter:latest
    container_name: redis-exporter
    restart: unless-stopped
    ports:
      - "9121:9121"
    environment:
      - REDIS_ADDR=REDIS_HOST_PLACEHOLDER:6379
    networks:
      - monitoring

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($$|/)'
    networks:
      - monitoring

volumes:
  prometheus_data:
  grafana_data:

networks:
  monitoring:
    driver: bridge
COMPOSE_EOF

# docker-compose.yml 내 REDIS_HOST 치환
sed -i "s|REDIS_HOST_PLACEHOLDER|${redis_host}|g" docker-compose.yml

# ── Grafana 프로비저닝: 데이터소스 ──
cat > grafana/provisioning/datasources/prometheus.yml << 'GF_DS_EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    uid: prometheus
GF_DS_EOF

# ── Grafana 프로비저닝: 대시보드 프로바이더 ──
cat > grafana/provisioning/dashboards/dashboards.yml << 'GF_DASH_EOF'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: 'Ticketing'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
GF_DASH_EOF

# ── prometheus.yml ──
cat > prometheus/prometheus.yml << 'PROM_EOF'
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  external_labels:
    env: 'prod'
    region: 'ap-northeast-2'

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          instance: 'monitoring-ec2'

  - job_name: 'cloudwatch-exporter'
    static_configs:
      - targets: ['cloudwatch-exporter:9106']
    scrape_interval: 60s

  - job_name: 'redis-exporter'
    static_configs:
      - targets: ['redis-exporter:9121']

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
PROM_EOF

# ── alertmanager.yml ──
cat > alertmanager/alertmanager.yml << 'ALERT_EOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait:      10s
  group_interval:  5m
  repeat_interval: 1h
  receiver: 'default'

receivers:
  - name: 'default'
    webhook_configs: []

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname']
ALERT_EOF

# ── cloudwatch exporter config ──
cat > cloudwatch/config.yml << 'CW_EOF'
region: ap-northeast-2

metrics:
  - aws_namespace: AWS/RDS
    aws_metric_name: CPUUtilization
    aws_dimensions: [DBInstanceIdentifier]
    aws_statistics: [Average]
    period_seconds: 60

  - aws_namespace: AWS/RDS
    aws_metric_name: DatabaseConnections
    aws_dimensions: [DBInstanceIdentifier]
    aws_statistics: [Average]
    period_seconds: 60

  - aws_namespace: AWS/RDS
    aws_metric_name: ReplicaLag
    aws_dimensions: [DBInstanceIdentifier]
    aws_statistics: [Average]
    period_seconds: 30

  - aws_namespace: AWS/SQS
    aws_metric_name: ApproximateNumberOfMessagesVisible
    aws_dimensions: [QueueName]
    aws_statistics: [Maximum]
    period_seconds: 30

  - aws_namespace: AWS/SQS
    aws_metric_name: NumberOfMessagesSent
    aws_dimensions: [QueueName]
    aws_statistics: [Sum]
    period_seconds: 60

  - aws_namespace: AWS/ElastiCache
    aws_metric_name: CurrConnections
    aws_dimensions: [CacheClusterId]
    aws_statistics: [Average]
    period_seconds: 60

  - aws_namespace: AWS/ElastiCache
    aws_metric_name: DatabaseMemoryUsagePercentage
    aws_dimensions: [CacheClusterId]
    aws_statistics: [Average]
    period_seconds: 60

  - aws_namespace: AWS/ElastiCache
    aws_metric_name: CacheHits
    aws_dimensions: [CacheClusterId]
    aws_statistics: [Sum]
    period_seconds: 60
CW_EOF

# ── prometheus rules ──
cat > prometheus/rules/ticketing.yml << 'RULES_EOF'
groups:
  - name: ticketing-critical
    rules:
      - alert: SQSQueueBacklog
        expr: aws_sqs_approximate_number_of_messages_visible_maximum > 500
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "SQS 큐 적체 {{ $value }}개"

      - alert: ServiceHealthCheckFailed
        expr: up{job=~"event-svc|reserv-svc|worker-svc"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }} 헬스체크 실패"

  - name: ticketing-warning
    rules:
      - alert: RDSReplicaLagHigh
        expr: aws_rds_replica_lag_average > 5
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Read Replica 지연 {{ $value }}초"

      - alert: RedisMemoryHigh
        expr: aws_elasticache_database_memory_usage_percentage_average > 75
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis 메모리 {{ $value }}% 사용중"

      - alert: RDSHighCPU
        expr: aws_rds_cpuutilization_average > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "RDS CPU {{ $value }}%"

      - alert: MonitoringEC2HighCPU
        expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 70
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "모니터링 서버 CPU {{ $value }}%"
RULES_EOF

# ── docker-compose 실행 ──
cd /opt/monitoring
docker-compose up -d
