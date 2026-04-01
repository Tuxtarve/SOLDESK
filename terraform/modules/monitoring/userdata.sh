#!/bin/bash
yum update -y
yum install -y docker git

systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Docker Compose 설치
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 모니터링 파일 디렉터리 생성
mkdir -p /opt/monitoring/{prometheus/rules,alertmanager,grafana/provisioning}

# Docker Compose 파일 복사 (프로비저닝은 ansible/SSM으로 처리)
cat > /opt/monitoring/start.sh << 'EOF'
#!/bin/bash
cd /opt/monitoring
docker-compose up -d
EOF
chmod +x /opt/monitoring/start.sh
