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

# ── 0.5. 영구 EBS 볼륨 import (이전 destroy/apply 사이클에서 살아남은 볼륨 재사용) ──
echo "=========================================="
echo " [0.5] 모니터링 영구 EBS 볼륨 확인"
echo "=========================================="
REGION_FOR_IMPORT="$(terraform output -raw aws_region 2>/dev/null || echo "ap-northeast-2")"
EBS_ID=$(aws ec2 describe-volumes \
  --region "$REGION_FOR_IMPORT" \
  --filters "Name=tag:Name,Values=ticketing-monitoring-data" "Name=tag:Persistent,Values=true" \
  --query "Volumes[?State=='available' || State=='in-use'] | [0].VolumeId" \
  --output text 2>/dev/null || echo "None")

if [ -n "$EBS_ID" ] && [ "$EBS_ID" != "None" ]; then
  if ! terraform state list 2>/dev/null | grep -q 'module.monitoring.aws_ebs_volume.monitoring_data'; then
    echo "기존 EBS 볼륨 발견: $EBS_ID — terraform state에 import 합니다 (데이터 보존)"
    terraform import 'module.monitoring.aws_ebs_volume.monitoring_data' "$EBS_ID"
  else
    echo "EBS 볼륨이 이미 state에 등록되어 있습니다: $EBS_ID"
  fi
else
  echo "기존 EBS 볼륨 없음 — 새로 생성됩니다 (첫 적용)"
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

# ── 4.5. KEDA 설치 (SQS 큐 길이 기반 worker-svc 자동 스케일링) ──
echo ""
echo "=========================================="
echo " [4.5/8] KEDA 설치"
echo "=========================================="
bash "$SCRIPTS/install-keda.sh"

# ── 5. 앱 배포 ──
echo ""
echo "=========================================="
echo " [5/8] ticketing 앱 배포"
echo "=========================================="
bash "$SCRIPTS/apply-ticketing-k8s.sh"

# ── 5.5. KEDA ScaledObject 적용 (worker-svc SQS 스케일링) ──
echo ""
echo "=========================================="
echo " [5.5/8] KEDA ScaledObject 적용"
echo "=========================================="
SQS_QUEUE_URL="$(terraform output -raw sqs_queue_url)"
AWS_REGION="$(terraform output -raw aws_region)"
export SQS_QUEUE_URL AWS_REGION

# 템플릿 → 실제 매니페스트 (envsubst로 ${SQS_QUEUE_URL}, ${AWS_REGION} 치환)
envsubst < "$ROOT/k8s/keda/worker-svc-scaledobject.yaml.tmpl" \
  | kubectl apply -f -
echo "ScaledObject 적용 완료 (queue=$SQS_QUEUE_URL)"

# KEDA가 HPA를 자동 생성할 때까지 잠깐 대기
sleep 5
kubectl get scaledobject -n ticketing
kubectl get hpa -n ticketing | grep keda || true

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

# ── 9. API Gateway VPC Link Integration 설정 ──
# Internal ALB가 ingress로 만들어진 후, listener ARN을 추출하여
# tfvars에 박고 terraform apply 재실행 → API GW Integration/Route 생성
# 흐름: 브라우저 → CloudFront → API GW → VPC Link → Internal ALB → EKS
echo ""
echo "=========================================="
echo " [9/9] API Gateway VPC Link Integration 연결"
echo "=========================================="
echo "Internal ALB 주소 대기 중 (ingress가 ALB 만들 때까지)..."
for i in $(seq 1 30); do
  ALB_ADDRESS="$(kubectl get ingress -n ticketing -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$ALB_ADDRESS" ]]; then break; fi
  echo "  대기 중... ($i/30)"
  sleep 10
done

if [[ -z "$ALB_ADDRESS" ]]; then
  echo "WARNING: Internal ALB 주소를 가져올 수 없습니다. API GW Integration이 생성되지 않습니다."
else
  echo "Internal ALB: $ALB_ADDRESS"

  # ALB의 HTTP listener ARN 추출 (API GW VPC Link Integration의 target)
  echo "ALB listener ARN 조회 중..."
  ALB_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?DNSName=='${ALB_ADDRESS}'].LoadBalancerArn | [0]" \
    --output text 2>/dev/null || true)"

  if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
    echo "WARNING: ALB ARN을 찾을 수 없습니다. ALB가 아직 등록 중일 수 있습니다."
  else
    LISTENER_ARN="$(aws elbv2 describe-listeners --region "$REGION" \
      --load-balancer-arn "$ALB_ARN" \
      --query "Listeners[?Port==\`80\`].ListenerArn | [0]" \
      --output text 2>/dev/null || true)"

    if [[ -z "$LISTENER_ARN" || "$LISTENER_ARN" == "None" ]]; then
      echo "WARNING: ALB listener ARN을 찾을 수 없습니다."
    else
      echo "Listener ARN: $LISTENER_ARN"

      # terraform.tfvars에 alb_listener_arn 저장 → 다음 apply에서 API GW Integration/Route 생성
      TFVARS="$TF_DIR/terraform.tfvars"
      if [[ -f "$TFVARS" ]] && grep -q '^alb_listener_arn' "$TFVARS"; then
        sed -i "s|^alb_listener_arn.*|alb_listener_arn = \"$LISTENER_ARN\"|" "$TFVARS"
      else
        echo "alb_listener_arn = \"$LISTENER_ARN\"" >> "$TFVARS"
      fi
      echo "terraform.tfvars에 alb_listener_arn 저장 완료"

      # Terraform 재실행 → API GW Integration + Route 생성, CloudFront 캐시 동작 갱신
      echo "Terraform apply 재실행 중 (API GW Integration 생성)..."
      terraform -chdir="$TF_DIR" apply -auto-approve
      echo "API GW Integration 생성 완료. CloudFront 전파 3~5분 소요"
    fi
  fi

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

    # ── 11. Grafana 대시보드 JSON 프로비저닝 ──
    echo ""
    echo "=========================================="
    echo " [11/11] Grafana 대시보드 프로비저닝"
    echo "=========================================="
    DASH_B64=$(base64 -w 0 < "$ROOT/monitoring/grafana/dashboards/ticketing-overview.json")
    aws ssm send-command \
      --instance-ids "$MONITORING_INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters "{\"commands\":[\"echo $DASH_B64 | base64 -d > /opt/monitoring/grafana/dashboards/ticketing-overview.json && docker restart grafana\"]}" \
      --output text --query "Command.CommandId" >/dev/null
    echo "Grafana 대시보드 프로비저닝 완료"
  else
    echo "WARNING: 모니터링 인스턴스 ID를 가져올 수 없어 Prometheus 설정을 건너뜁니다."
  fi
fi

echo ""
echo "=========================================="
echo " 전체 셋업 완료!"
echo "=========================================="
API_GW_ENDPOINT="$(terraform output -raw api_gateway_endpoint 2>/dev/null || echo '(아직 미생성)')"
echo "  프론트엔드:    https://${CLOUDFRONT_DOMAIN}"
echo "  API (사용자):  https://${CLOUDFRONT_DOMAIN}/api/events"
echo "  API GW (직접): ${API_GW_ENDPOINT}/api/events"
echo "  Internal ALB:  ${ALB_ADDRESS} (VPC 내부에서만 접근 가능)"
echo "  kubectl get nodes"
echo "  kubectl get pods -n ticketing"
