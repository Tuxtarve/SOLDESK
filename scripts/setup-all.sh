#!/usr/bin/env bash
# terraform apply 후 EKS 클러스터 전체 셋업을 자동으로 수행합니다.
# 사용법: bash scripts/setup-all.sh
# DB_PASSWORD 환경변수가 필요합니다: export DB_PASSWORD='your-password'
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

# ── 0. DB_PASSWORD 확인 ──
if [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "ERROR: DB_PASSWORD 환경변수를 먼저 설정하세요." >&2
  echo "  export DB_PASSWORD='your-password'" >&2
  exit 1
fi

# ── 1. Terraform Apply ──
echo "=========================================="
echo " [1/8] Terraform Apply"
echo "=========================================="
terraform apply -auto-approve

# ── 2. kubeconfig 설정 ──
echo ""
echo "=========================================="
echo " [2/8] kubeconfig 설정"
echo "=========================================="
CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
REGION="$(terraform output -raw aws_region)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
echo "kubeconfig 설정 완료"

# ── 3. AWS Load Balancer Controller 설치 ──
echo ""
echo "=========================================="
echo " [3/8] AWS Load Balancer Controller 설치"
echo "=========================================="
bash "$SCRIPTS/install-aws-load-balancer-controller.sh"

# ── 4. Cluster Autoscaler 설치 ──
echo ""
echo "=========================================="
echo " [4/8] Cluster Autoscaler 설치"
echo "=========================================="
bash "$SCRIPTS/install-cluster-autoscaler.sh"

# ── 5. 앱 배포 ──
echo ""
echo "=========================================="
echo " [5/8] ticketing 앱 배포"
echo "=========================================="
bash "$SCRIPTS/apply-ticketing-k8s.sh"

# ── 6. DB 스키마 초기화 ──
echo ""
echo "=========================================="
echo " [6/8] DB 스키마 초기화"
echo "=========================================="
DB_WRITER_HOST="$(terraform output -raw rds_writer_endpoint)"

kubectl run mysql-init --image=mysql:8.0 --restart=Never -n ticketing \
  --command -- sleep 3600 2>/dev/null || true
echo "MySQL 클라이언트 파드 대기 중..."
kubectl wait --for=condition=Ready pod/mysql-init -n ticketing --timeout=120s

cat "$ROOT/db/schema.sql" | kubectl exec -i mysql-init -n ticketing -- \
  mysql --force --default-character-set=utf8mb4 -h "$DB_WRITER_HOST" -u root -p"$DB_PASSWORD" 2>&1 || true

cat "$ROOT/db/seed.sql" | kubectl exec -i mysql-init -n ticketing -- \
  mysql --default-character-set=utf8mb4 -h "$DB_WRITER_HOST" -u root -p"$DB_PASSWORD" 2>&1 || true

kubectl delete pod mysql-init -n ticketing --wait=false
echo "DB 스키마 + 시드 데이터 적용 완료"

# ── 7. Docker 이미지 빌드 & ECR Push ──
echo ""
echo "=========================================="
echo " [7/8] Docker 이미지 빌드 & ECR Push"
echo "=========================================="
ACCOUNT_ID="$(terraform output -raw aws_account_id)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

for SVC in event-svc reserv-svc worker-svc; do
  echo "빌드 & 푸시: $SVC"
  docker build -t "${ECR_REGISTRY}/ticketing/${SVC}:latest" "$ROOT/services/${SVC}"
  docker push "${ECR_REGISTRY}/ticketing/${SVC}:latest"
done

kubectl rollout restart deployment -n ticketing
echo "이미지 배포 완료, 파드 재시작 중..."
kubectl rollout status deployment/event-svc -n ticketing --timeout=120s
kubectl rollout status deployment/reserv-svc -n ticketing --timeout=120s
kubectl rollout status deployment/worker-svc -n ticketing --timeout=120s

# ── 8. 프론트엔드 S3 배포 ──
echo ""
echo "=========================================="
echo " [8/8] 프론트엔드 S3 배포"
echo "=========================================="
BUCKET="ticketing-frontend-${ACCOUNT_ID}"
COGNITO_CLIENT_ID="$(terraform output -raw cognito_client_id)"

# 플레이스홀더를 실제 값으로 치환하여 임시 파일 생성 후 업로드
sed "s|__COGNITO_CLIENT_ID__|${COGNITO_CLIENT_ID}|g" \
  "$ROOT/frontend/src/index.html" > /tmp/index.html

aws s3 cp /tmp/index.html "s3://${BUCKET}/index.html" \
  --content-type "text/html; charset=utf-8" --region "$REGION"
rm -f /tmp/index.html

CF_DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?Id=='S3-frontend']].Id | [0]" \
  --output text 2>/dev/null || true)"
if [[ -n "$CF_DIST_ID" && "$CF_DIST_ID" != "None" ]]; then
  aws cloudfront create-invalidation --distribution-id "$CF_DIST_ID" --paths "/*" >/dev/null
  echo "CloudFront 캐시 무효화 완료"
fi

CLOUDFRONT_DOMAIN="$(terraform output -raw cloudfront_domain)"

# ── 9. CloudFront에 ALB API 라우팅 설정 ──
echo ""
echo "=========================================="
echo " [9/9] CloudFront API 라우팅 설정"
echo "=========================================="
echo "ALB 주소 대기 중..."
for i in $(seq 1 30); do
  ALB_ADDRESS="$(kubectl get ingress -n ticketing -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$ALB_ADDRESS" ]]; then break; fi
  echo "  대기 중... ($i/30)"
  sleep 10
done

if [[ -z "$ALB_ADDRESS" ]]; then
  echo "WARNING: ALB 주소를 가져올 수 없습니다. CloudFront API 라우팅을 수동으로 설정하세요."
else
  echo "ALB: $ALB_ADDRESS"

  # terraform.tfvars에 ALB DNS 저장 → 이후 terraform apply 시 자동 반영
  TFVARS="$TF_DIR/terraform.tfvars"
  if [[ -f "$TFVARS" ]] && grep -q '^alb_dns_name' "$TFVARS"; then
    sed -i "s|^alb_dns_name.*|alb_dns_name = \"$ALB_ADDRESS\"|" "$TFVARS"
  else
    echo "alb_dns_name = \"$ALB_ADDRESS\"" >> "$TFVARS"
  fi
  echo "terraform.tfvars에 alb_dns_name 저장 완료"

  # Terraform으로 CloudFront 업데이트 (상태 일관성 유지)
  echo "Terraform apply로 CloudFront ALB 라우팅 설정 중..."
  terraform -chdir="$TF_DIR" apply -auto-approve
  echo "CloudFront ALB 라우팅 설정 완료 (전파 3~5분 소요)"

  # ── 10. 모니터링 Prometheus에 EKS 서비스 scrape 등록 ──
  echo ""
  echo "=========================================="
  echo " [10/10] Prometheus EKS 서비스 scrape 등록"
  echo "=========================================="
  MONITORING_INSTANCE_ID="$(terraform output -raw monitoring_instance_id 2>/dev/null || true)"
  if [[ -n "$MONITORING_INSTANCE_ID" && "$MONITORING_INSTANCE_ID" != "" ]]; then
    PROM_B64=$(base64 -w 0 << PROMEOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    env: prod
    region: ap-northeast-2

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: node-exporter
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          instance: monitoring-ec2

  - job_name: cloudwatch-exporter
    static_configs:
      - targets: ['cloudwatch-exporter:9106']
    scrape_interval: 60s

  - job_name: redis-exporter
    static_configs:
      - targets: ['redis-exporter:9121']

  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: event-svc
    static_configs:
      - targets: ['${ALB_ADDRESS}:80']
    metrics_path: /metrics
    honor_labels: true

  - job_name: reserv-svc
    static_configs:
      - targets: ['${ALB_ADDRESS}:80']
    metrics_path: /reserv-metrics
    honor_labels: true

  - job_name: worker-svc
    static_configs:
      - targets: ['${ALB_ADDRESS}:80']
    metrics_path: /worker-metrics
    honor_labels: true
PROMEOF
)
    aws ssm send-command \
      --instance-ids "$MONITORING_INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters "{\"commands\":[\"echo $PROM_B64 | base64 -d > /opt/monitoring/prometheus/prometheus.yml && docker restart prometheus\"]}" \
      --output text --query "Command.CommandId" >/dev/null
    echo "Prometheus에 EKS 서비스 scrape 등록 완료 (ALB: $ALB_ADDRESS)"
  else
    echo "WARNING: 모니터링 인스턴스 ID를 가져올 수 없어 Prometheus 설정을 건너뜁니다."
  fi
fi

echo ""
echo "=========================================="
echo " 전체 셋업 완료!"
echo "=========================================="
echo "  프론트엔드: https://${CLOUDFRONT_DOMAIN}"
echo "  백엔드 API: http://${ALB_ADDRESS}/api/events"
echo "  kubectl get nodes"
echo "  kubectl get pods -n ticketing"
