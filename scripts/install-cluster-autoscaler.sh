#!/usr/bin/env bash
# EKS에 Cluster Autoscaler 설치 (Helm).
# 사전: helm, kubectl, aws CLI / update-kubeconfig, terraform apply
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
ROLE_ARN="$(terraform output -raw cluster_autoscaler_role_arn)"
REGION="$(terraform output -raw aws_region)"

echo "cluster=$CLUSTER_NAME region=$REGION"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm 이 필요합니다. 예: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
helm repo update

# cluster-autoscaler image는 EKS 마이너 버전과 일치시켜야 함.
# v1.32+ image는 DRA(ResourceClaim/ResourceSlice/DeviceClass) API를 watch하는데
# k8s 1.30 클러스터에는 그 API가 없어서 reflector가 영원히 실패 → main loop가
# 멈추고 scale-up 결정 자체를 안 함(silently dead). chart/image 모두 pin.
CHART_VERSION="9.56.0"
IMAGE_TAG="v1.30.5"

VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
cat >"$VALUES" <<EOF
autoDiscovery:
  clusterName: ${CLUSTER_NAME}
awsRegion: ${REGION}
image:
  tag: ${IMAGE_TAG}
rbac:
  serviceAccount:
    create: true
    name: cluster-autoscaler
    annotations:
      eks.amazonaws.com/role-arn: ${ROLE_ARN}
extraArgs:
  balance-similar-node-groups: true
  skip-nodes-with-local-storage: false
  expander: least-waste
  scale-down-delay-after-add: 5m
  scale-down-unneeded-time: 5m
EOF

if helm list -n kube-system | grep -q cluster-autoscaler; then
  echo "이미 설치됨 → upgrade"
  helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
    -n kube-system --version "$CHART_VERSION" -f "$VALUES" --wait
else
  helm install cluster-autoscaler autoscaler/cluster-autoscaler \
    -n kube-system --version "$CHART_VERSION" -f "$VALUES" --wait
fi

echo "완료: kubectl get deployment -n kube-system cluster-autoscaler"
