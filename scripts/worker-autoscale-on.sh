#!/usr/bin/env bash
# ON(빠름):
# - 서버(write-api)는 bulk 큐로 라우팅 → worker-svc 가 분산 처리(= 빠름)
# - worker-svc-ui 는 항상 1로 대기(새 요청/쿼리 처리용)
# - KEDA ScaledObject(worker-svc-sqs) paused 해제 → worker-svc 오토스케일
set -euo pipefail

NS="${KUBECTL_NAMESPACE:-ticketing}"
CM="${TICKETING_CONFIGMAP_NAME:-ticketing-config}"

_die() { echo "ERROR: $*" >&2; exit 1; }

_secret_has_key() {
  local key="$1"
  kubectl -n "$NS" get secret ticketing-secrets -o "jsonpath={.data.${key}}" 2>/dev/null | tr -d '\r\n'
}

_diag_keda() {
  echo "=== diag: keda scaledobject ===" >&2
  kubectl -n "$NS" get scaledobject worker-svc-sqs -o wide >&2 || true
  kubectl -n "$NS" describe scaledobject worker-svc-sqs >&2 || true
}

trap '_diag_keda' ERR

kubectl -n "$NS" get cm "$CM" >/dev/null 2>&1 || _die "ConfigMap not found: $NS/$CM"
kubectl -n "$NS" get deploy/worker-svc >/dev/null 2>&1 || _die "Deployment not found: $NS/worker-svc"
kubectl -n "$NS" get scaledobject worker-svc-sqs >/dev/null 2>&1 || _die "ScaledObject not found: $NS/worker-svc-sqs (apply k8s/keda)"
kubectl -n "$NS" get secret ticketing-secrets >/dev/null 2>&1 || _die "Secret not found: $NS/ticketing-secrets (run k8s/scripts/apply-secrets-from-terraform.sh)"

if [[ -z "$(_secret_has_key SQS_QUEUE_URL)" ]]; then
  _die "Secret missing key: SQS_QUEUE_URL (in $NS/ticketing-secrets)"
fi

kubectl -n "$NS" patch cm "$CM" --type merge -p '{"data":{"BOOKING_QUEUE_MODE":"bulk"}}' >/dev/null
kubectl -n "$NS" rollout restart deploy/write-api >/dev/null 2>&1 || true

kubectl -n "$NS" scale deploy/worker-svc-ui --replicas=1 2>/dev/null || true
kubectl -n "$NS" scale deploy/worker-svc --replicas=1 2>/dev/null || true

kubectl annotate scaledobject worker-svc-sqs -n "$NS" autoscaling.keda.sh/paused- >/dev/null

kubectl -n "$NS" get deploy write-api worker-svc worker-svc-ui -o wide
echo "ON OK: BOOKING_QUEUE_MODE=bulk (fast), worker-svc-ui=1, worker-svc autoscale=KEDA(unpaused)"

