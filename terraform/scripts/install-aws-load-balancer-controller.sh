#!/usr/bin/env bash
# EKS에 AWS Load Balancer Controller 설치 (Helm).
# 사전: helm, kubectl, aws CLI / update-kubeconfig, terraform apply
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT"
cd "$TF_DIR"

CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
VPC_ID="$(terraform output -raw vpc_id)"
ROLE_ARN="$(terraform output -raw alb_controller_role_arn)"
REGION="$(terraform output -raw aws_region)"

echo "cluster=$CLUSTER_NAME vpc=$VPC_ID region=$REGION"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm 이 필요합니다. 예: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
cat >"$VALUES" <<EOF
clusterName: ${CLUSTER_NAME}
region: ${REGION}
vpcId: ${VPC_ID}
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

if helm list -n kube-system | grep -q aws-load-balancer-controller; then
  echo "이미 설치됨 → upgrade"
  helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system -f "$VALUES" --wait
else
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system -f "$VALUES" --wait
fi

echo "완료: kubectl get deployment -n kube-system aws-load-balancer-controller"
