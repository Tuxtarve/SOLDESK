#!/usr/bin/env bash
# EKS에 ArgoCD 설치 (Helm) + ticketing Application 등록.
# 사전: helm, kubectl (kubeconfig 설정), terraform output 가능 상태
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm 이 필요합니다." >&2
  exit 1
fi

NAMESPACE="argocd"
RELEASE="argocd"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update >/dev/null

# ── values: ALB/Ingress 안 만듦 (port-forward 접근). 메모리 가벼운 옵션 ──
VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
cat >"$VALUES" <<'EOF'
configs:
  params:
    server.insecure: true
server:
  service:
    type: ClusterIP
controller:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
repoServer:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
applicationSet:
  enabled: false
notifications:
  enabled: false
dex:
  enabled: false
EOF

if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^${RELEASE}\b"; then
  echo "이미 설치됨 → upgrade"
  helm upgrade "$RELEASE" argo/argo-cd -n "$NAMESPACE" -f "$VALUES" --wait
else
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  helm install "$RELEASE" argo/argo-cd -n "$NAMESPACE" -f "$VALUES" --wait
fi

echo "argocd-server rollout 대기..."
kubectl rollout status deployment/argocd-server -n "$NAMESPACE" --timeout=300s

# ── ticketing Application 등록 ────────────────────────────────────
APP_MANIFEST="$ROOT/argocd/application.yaml"
if [[ -f "$APP_MANIFEST" ]]; then
  echo "Application 등록: $APP_MANIFEST"
  kubectl apply -f "$APP_MANIFEST"
else
  echo "WARN: $APP_MANIFEST 없음 — Application 등록 생략" >&2
fi

# ── admin 비밀번호 + 접속 안내 ────────────────────────────────────
ADMIN_PW=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")

cat <<EOF

==================================================================
ArgoCD 설치 완료

UI 접속 (port-forward):
  kubectl port-forward -n $NAMESPACE svc/argocd-server 8080:80
  → http://localhost:8080

로그인:
  username: admin
  password: ${ADMIN_PW:-<argocd-initial-admin-secret 확인>}

Application 상태:
  kubectl get application -n $NAMESPACE
==================================================================
EOF
