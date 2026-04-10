#!/usr/bin/env bash
set -eu
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

echo "Installing aws-load-balancer-controller via Helm..."

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${VPC_ID:?VPC_ID is required}"
: "${ROLE_ARN:?ROLE_ARN is required}"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set "clusterName=${CLUSTER_NAME}" \
  --set "region=${AWS_REGION}" \
  --set "vpcId=${VPC_ID}" \
  --set replicaCount=1 \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${ROLE_ARN}"

