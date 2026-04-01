#!/usr/bin/env bash
# ticketing 네임스페이스·ConfigMap·Secret·Deployment·Ingress 적용
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
K8S="$ROOT/k8s"
cd "$TF_DIR"

: "${COGNITO_JSON:=}"

if [[ -z "${COGNITO_JSON}" ]]; then
  POOL_ARN="$(terraform output -raw cognito_user_pool_arn)"
  CLIENT_ID="$(terraform output -raw cognito_client_id)"
  DOMAIN="$(terraform output -raw cognito_domain)"
  COGNITO_JSON="$(printf '{"UserPoolArn":"%s","UserPoolClientId":"%s","UserPoolDomain":"%s"}' \
    "$POOL_ARN" "$CLIENT_ID" "$DOMAIN")"
 fi
export COGNITO_JSON

DB_W="$(terraform output -raw rds_writer_endpoint)"
DB_R="$(terraform output -raw rds_reader_endpoint)"
REDIS_H="$(terraform output -raw redis_endpoint)"
SQS_URL="$(terraform output -raw sqs_queue_url)"
SNS_ARN="$(terraform output -raw sns_confirmed_topic_arn)"
TICKETS_BUCKET="$(terraform output -raw tickets_bucket_name)"
# .gitignore 또는 tfvars 에 맞춘 비밀번호 — 필요 시 환경변수로 덮어씀
: "${DB_PASSWORD:=dkzndk34}"

TMP_INGRESS="$(mktemp)"
trap 'rm -f "$TMP_INGRESS"' EXIT
if command -v envsubst >/dev/null 2>&1; then
  envsubst < "$K8S/ingress.yaml" > "$TMP_INGRESS"
else
  COGNITO_JSON="$COGNITO_JSON" python3 -c "
import os, pathlib, sys
val = os.environ['COGNITO_JSON']
t = pathlib.Path(sys.argv[1]).read_text()
t = t.replace(\"'\${COGNITO_JSON}'\", \"'\" + val + \"'\")
pathlib.Path(sys.argv[2]).write_text(t)
" "$K8S/ingress.yaml" "$TMP_INGRESS"
fi

kubectl apply -f "$K8S/namespace.yaml"
kubectl apply -f "$K8S/configmap.yaml"

kubectl create secret generic ticketing-secrets \
  --from-literal=DB_WRITER_HOST="$DB_W" \
  --from-literal=DB_READER_HOST="$DB_R" \
  --from-literal=DB_USER=root \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=REDIS_HOST="$REDIS_H" \
  --from-literal=SQS_QUEUE_URL="$SQS_URL" \
  --from-literal=SNS_CONFIRMED_ARN="$SNS_ARN" \
  --from-literal=S3_TICKETS_BUCKET="$TICKETS_BUCKET" \
  -n ticketing \
  --dry-run=client -o yaml | kubectl apply -f -

ACCOUNT_ID="$(terraform output -raw aws_account_id)"
REGION="$(terraform output -raw aws_region)"
for SVC in event-svc reserv-svc worker-svc; do
  sed -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" -e "s|ap-northeast-2|${REGION}|g" \
    "$K8S/${SVC}/deployment.yaml" | kubectl apply -f -
  kubectl apply -f "$K8S/${SVC}/service.yaml"
done
kubectl apply -f "$K8S/event-svc/hpa.yaml"
kubectl apply -f "$K8S/reserv-svc/hpa.yaml"

kubectl apply -f "$TMP_INGRESS"

echo "적용 완료."
echo "Ingress 주소 확인: kubectl get ingress -n ticketing"
echo "이미지가 ECR에 없으면 Pod 가 ImagePullBackOff 입니다. CI/CD 로 푸시하거나 로컬에서 docker build/push 하세요."
