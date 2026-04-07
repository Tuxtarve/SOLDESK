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
  mysql -h "$DB_WRITER_HOST" -u root -p"$DB_PASSWORD" 2>/dev/null

kubectl delete pod mysql-init -n ticketing --wait=false
echo "DB 스키마 적용 완료"

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
aws s3 cp "$ROOT/frontend/src/index.html" "s3://${BUCKET}/index.html" \
  --content-type "text/html; charset=utf-8" --region "$REGION"

CF_DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?Id=='S3-frontend']].Id | [0]" \
  --output text 2>/dev/null || true)"
if [[ -n "$CF_DIST_ID" && "$CF_DIST_ID" != "None" ]]; then
  aws cloudfront create-invalidation --distribution-id "$CF_DIST_ID" --paths "/*" >/dev/null
  echo "CloudFront 캐시 무효화 완료"
fi

CLOUDFRONT_DOMAIN="$(terraform output -raw cloudfront_domain)"
ALB_ADDRESS="$(kubectl get ingress -n ticketing -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')"

echo ""
echo "=========================================="
echo " 전체 셋업 완료!"
echo "=========================================="
echo "  프론트엔드: https://${CLOUDFRONT_DOMAIN}"
echo "  백엔드 API: http://${ALB_ADDRESS}/api/events"
echo "  kubectl get nodes"
echo "  kubectl get pods -n ticketing"
