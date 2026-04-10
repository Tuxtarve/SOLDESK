#!/usr/bin/env bash
# kubectl apply 로 Ingress(ALB)가 생긴 뒤, 실제 ALB DNS로 S3의 api-origin.js 를 덮어씀.
# (endpoints.json 은 사용하지 않음 — JS 정적 파일만 ALB 주소를 참조.)
# terraform apply 끝의 post_apply_k8s_bootstrap 에서 호출 — 두 번째 apply 없이 브라우저용 API 오리진 확정.
set -euo pipefail

if [[ -n "${REPO_ROOT:-}" ]]; then
  ROOT_DIR="$(cd "${REPO_ROOT}" && pwd)"
else
  _self="${BASH_SOURCE[0]:-$0}"
  ROOT_DIR="$(cd "$(dirname "${_self}")/../.." && pwd)"
fi
TF_DIR="$ROOT_DIR/terraform"

_tf_region="$(terraform -chdir="$TF_DIR" output -raw aws_region 2>/dev/null || true)"
export AWS_REGION="${AWS_REGION:-${_tf_region:-}}"
if [[ -z "${AWS_REGION}" ]]; then
  echo "ERROR: AWS_REGION is required (set env or ensure terraform output aws_region is available)" >&2
  exit 1
fi
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"

NAMESPACE="${TICKETING_NAMESPACE:-${TICKETING_NS:-ticketing}}"
INGRESS_NAME="${INGRESS_NAME:-ticketing-ingress}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-600}"
SLEEP_SEC="${SLEEP_SEC:-5}"

cf_url="$(terraform -chdir="$TF_DIR" output -raw frontend_cloudfront_url 2>/dev/null || true)"
if [[ -n "${cf_url}" && "${cf_url}" != "null" ]]; then
  echo "frontend_cloudfront_url 이 설정됨 — 브라우저는 동일 오리진 /api/* 를 씁니다. api-origin.js 동기화는 건너뜁니다."
  exit 0
fi

bucket="$(terraform -chdir="$TF_DIR" output -raw frontend_bucket_name 2>/dev/null || true)"
if [[ -z "${bucket}" || "${bucket}" == "null" ]]; then
  echo "frontend_bucket_name 없음 — S3 hosting(v2) 미적용 상태로 보고 api-origin.js 동기화를 건너뜁니다."
  exit 0
fi

echo "=== Ingress ${NAMESPACE}/${INGRESS_NAME} 에서 ALB 호스트 대기 (최대 ${MAX_WAIT_SEC}s) ==="
host=""
elapsed=0
while [[ "${elapsed}" -lt "${MAX_WAIT_SEC}" ]]; do
  host="$(kubectl get ingress -n "${NAMESPACE}" "${INGRESS_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    break
  fi
  sleep "${SLEEP_SEC}"
  elapsed=$((elapsed + SLEEP_SEC))
done

if [[ -z "${host}" ]]; then
  echo "ERROR: ALB hostname 을 받지 못했습니다. kubectl describe ingress -n ${NAMESPACE} ${INGRESS_NAME} 확인" >&2
  exit 1
fi

origin="http://${host}"
tmp="$(mktemp)"
# ALB 호스트명은 따옴표 불필요; JSON 대신 단일 설정 스크립트로만 배포
printf 'window.__TICKETING_API_ORIGIN__="%s";\n' "${origin}" >"${tmp}"

echo "=== s3://${bucket}/api-origin.js ← ${origin} ==="
aws s3 cp "${tmp}" "s3://${bucket}/api-origin.js" \
  --content-type "application/javascript; charset=utf-8" \
  --cache-control "no-store, max-age=0"

rm -f "${tmp}"
echo "완료. 브라우저에서 S3 사이트 새로고침(api-origin.js 반영, 필요 시 캐시 비우기)."
