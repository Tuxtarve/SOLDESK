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

VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
cat >"$VALUES" <<EOF
autoDiscovery:
  clusterName: ${CLUSTER_NAME}
awsRegion: ${REGION}
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
    -n kube-system -f "$VALUES" --wait
else
  helm install cluster-autoscaler autoscaler/cluster-autoscaler \
    -n kube-system -f "$VALUES" --wait
fi

echo "완료: kubectl get deployment -n kube-system cluster-autoscaler"
