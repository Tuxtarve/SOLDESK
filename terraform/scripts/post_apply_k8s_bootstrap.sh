#!/usr/bin/env bash
# terraform apply 마지막에 null_resource 가 호출 — 두 번째 terraform apply 없이
# 시크릿 적용 → 매니페스트 → (옵션) S3 api-origin.js 동기화 → 롤아웃까지 한 번에 수행.
set -euo pipefail

# tr … | bash 으로 실행될 때 BASH_SOURCE 가 비므로 TF 가 REPO_ROOT 를 넘김
: "${REPO_ROOT:?}"

: "${EKS_CLUSTER_NAME:?}"
: "${AWS_REGION:?}"
: "${DB_PASSWORD:?}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found. Install kubectl before terraform apply (same host that runs local-exec)." >&2
  exit 127
fi

NS="${TICKETING_NAMESPACE:-ticketing}"
CM="${TICKETING_CONFIGMAP_NAME:-ticketing-config}"
WORKER="${WORKER_DEPLOYMENT_NAME:-worker-svc}"
READ_API="${READ_API_DEPLOYMENT_NAME:-read-api}"
WRITE_API="${WRITE_API_DEPLOYMENT_NAME:-write-api}"
INGRESS_NAME="${K8S_INGRESS_NAME:-ticketing-ingress}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
ECR_REPO_TICKETING_WAS="${ECR_REPO_TICKETING_WAS:-ticketing/ticketing-was}"
ECR_REPO_WORKER_SVC="${ECR_REPO_WORKER_SVC:-ticketing/worker-svc}"
DB_SCHEMA_NAME="${DB_SCHEMA_NAME:-ticketing}"

normalize_crlf() {
  local f
  for f in "$REPO_ROOT"/k8s/scripts/*.sh "$REPO_ROOT"/terraform/scripts/*.sh "$REPO_ROOT"/scripts/*.sh; do
    [ -f "$f" ] || continue
    sed -i 's/\r$//' "$f" 2>/dev/null || true
  done
  while IFS= read -r -d '' f; do
    sed -i 's/\r$//' "$f" 2>/dev/null || true
  done < <(find "$REPO_ROOT/terraform/modules" -type f -name '*.sh' -print0 2>/dev/null || true)
}

if [[ -f "$REPO_ROOT/scripts/normalize-line-endings.sh" ]]; then
  bash "$REPO_ROOT/scripts/normalize-line-endings.sh" >/dev/null 2>&1 || true
else
  normalize_crlf
fi

echo "=== post_apply_k8s_bootstrap: kubeconfig ($EKS_CLUSTER_NAME) ==="
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"

export DB_PASSWORD
echo "=== apply-secrets-from-terraform ==="
NAMESPACE="$NS" bash "$REPO_ROOT/k8s/scripts/apply-secrets-from-terraform.sh"

echo "=== kubectl apply -k (rendered) ==="
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

TF_DIR="$REPO_ROOT/terraform"
ACCOUNT_ID="$(terraform -chdir="$TF_DIR" output -raw aws_account_id 2>/dev/null)"
REGION="$(terraform -chdir="$TF_DIR" output -raw aws_region 2>/dev/null)"
SQS_ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw sqs_access_role_arn 2>/dev/null)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
WAS_IMAGE="${ECR_REGISTRY}/${ECR_REPO_TICKETING_WAS}:${IMAGE_TAG}"
WORKER_IMAGE="${ECR_REGISTRY}/${ECR_REPO_WORKER_SVC}:${IMAGE_TAG}"

tmp_k8s="$(mktemp -d)"
cp -R "$REPO_ROOT/k8s" "$tmp_k8s/k8s"

kubectl apply -k "$tmp_k8s/k8s" -n "$NS"

# kustomize 바이너리 없이도 동일하게 이미지 태그/레지스트리를 반영.
# (kustomization.yaml 의 images/newTag 을 편집하는 대신, 실제 Deployment에 이미지 주입)
kubectl -n "$NS" set image deploy/"$READ_API" "read-api=${WAS_IMAGE}" >/dev/null
kubectl -n "$NS" set image deploy/"$WRITE_API" "write-api=${WAS_IMAGE}" >/dev/null
kubectl -n "$NS" set image deploy/"$WORKER" "worker-svc=${WORKER_IMAGE}" >/dev/null

kubectl -n "$NS" annotate sa sqs-access-sa "eks.amazonaws.com/role-arn=${SQS_ROLE_ARN}" --overwrite >/dev/null 2>&1 || true

if [[ "${SYNC_S3_ENDPOINTS:-0}" == "1" ]]; then
  echo "=== sync S3 api-origin.js from Ingress (same apply, no second terraform) ==="
  TICKETING_NAMESPACE="$NS" INGRESS_NAME="$INGRESS_NAME" bash "$REPO_ROOT/k8s/scripts/sync-s3-endpoints-from-ingress.sh"
fi

echo "=== patch configmap + rollouts ==="
kubectl -n "$NS" patch cm "$CM" --type merge -p "{\"data\":{\"DB_NAME\":\"${DB_SCHEMA_NAME}\"}}" || true
kubectl -n "$NS" patch cm "$CM" --type merge -p "{\"data\":{\"AWS_REGION\":\"$AWS_REGION\"}}" || true
kubectl -n "$NS" rollout restart deploy/"$WORKER" || true
kubectl -n "$NS" rollout restart deploy/"$READ_API" || true
kubectl -n "$NS" rollout restart deploy/"$WRITE_API" || true

echo "=== post_apply_k8s_bootstrap done ==="
