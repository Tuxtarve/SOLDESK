#!/usr/bin/env bash
# OFF(느림):
# - 서버(write-api)는 UI 큐로만 라우팅 → worker-svc-ui 1개가 처리(= 느림)
# - bulk 워커(worker-svc)는 1(기본 대기), KEDA ScaledObject paused(오토스케일 OFF)
# - UI 워커(worker-svc-ui)는 1로 유지(항상 대기/처리 가능)
set -euo pipefail

NS="${KUBECTL_NAMESPACE:-ticketing}"
CM="${TICKETING_CONFIGMAP_NAME:-ticketing-config}"

kubectl -n "$NS" patch cm "$CM" --type merge -p '{"data":{"BOOKING_QUEUE_MODE":"ui"}}' >/dev/null
kubectl -n "$NS" rollout restart deploy/write-api >/dev/null 2>&1 || true

kubectl annotate scaledobject worker-svc-sqs -n "$NS" autoscaling.keda.sh/paused=true --overwrite >/dev/null 2>&1 || true
kubectl -n "$NS" scale deploy/worker-svc --replicas=1 2>/dev/null || true
kubectl -n "$NS" scale deploy/worker-svc-ui --replicas=1 2>/dev/null || true

kubectl -n "$NS" get deploy write-api worker-svc worker-svc-ui -o wide 2>/dev/null || true
echo "OFF OK: BOOKING_QUEUE_MODE=ui (slow), worker-svc=1 (pinned), worker-svc-ui=1, worker autoscale=KEDA(paused)"

