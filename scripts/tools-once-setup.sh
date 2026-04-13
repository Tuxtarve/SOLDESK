#!/usr/bin/env bash
# tools-once Pod 하나만 사용: Running 이면 스크립트만 rsync 성격으로 갱신, 아니면 같은 이름으로 재기동 후 동기화.
set -eu

NS="${KUBECTL_NAMESPACE:-ticketing}"
POD="${TOOLS_ONCE_POD:-tools-once}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

_sync_scripts() {
  kubectl -n "$NS" exec "$POD" -- mkdir -p /work/ticketing-db/scripts /work/ticketing-db/terraform
  kubectl cp "$REPO_ROOT/scripts/." "$NS/$POD:/work/ticketing-db/scripts/"
  echo "Synced $REPO_ROOT/scripts/. -> $NS/$POD:/work/ticketing-db/scripts/"
}

_need_fresh_pod() {
  if ! kubectl -n "$NS" get pod "$POD" &>/dev/null; then
    return 0
  fi
  local phase
  phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')
  [ "$phase" = "Running" ] && return 1
  return 0
}

if ! _need_fresh_pod; then
  _sync_scripts
  exit 0
fi

kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
spec:
  priorityClassName: ticketing-priority-ops
  serviceAccountName: sqs-access-sa
  restartPolicy: Never
  containers:
    - name: tools
      image: python:3.12-slim
      command: ["/bin/sh", "-c", "tail -f /dev/null"]
      resources:
        requests:
          cpu: "25m"
          memory: "64Mi"
        limits:
          cpu: "1"
          memory: "1Gi"
      envFrom:
        - configMapRef:
            name: ticketing-config
        - secretRef:
            name: ticketing-secrets
EOF

i=0
max=200
while [ "$i" -lt "$max" ]; do
  reason=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
  case "$reason" in
    ImagePullBackOff|ErrImagePull|CrashLoopBackOff|CreateContainerConfigError|InvalidImageName)
      exit 1
      ;;
  esac
  ready=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  if [ "$ready" = "true" ]; then
    break
  fi
  sleep 3
  i=$((i + 1))
done
if [ "$i" -ge "$max" ]; then
  exit 1
fi

_sync_scripts
kubectl -n "$NS" exec "$POD" -- python -m pip install -q --upgrade "pip>=26,<27"
kubectl -n "$NS" exec "$POD" -- pip install -q boto3 pymysql redis
