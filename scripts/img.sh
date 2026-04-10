#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
TAG="${TAG:-latest}"

if [ -z "${ACCOUNT_ID}" ]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

if [ -z "${AWS_REGION}" ]; then
  AWS_REGION="$(terraform -chdir="$ROOT_DIR/terraform" output -raw aws_region 2>/dev/null || true)"
fi
if [ -z "${AWS_REGION}" ]; then
  echo "ERROR: AWS_REGION is required (set env or ensure terraform output aws_region is available)" >&2
  exit 1
fi

ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
WAS_DIR="${ROOT_DIR}/services/ticketing-was"
WORKER_DIR="${ROOT_DIR}/services/worker-svc"
WAS_IMAGE="${ECR_BASE}/ticketing/ticketing-was:${TAG}"
WORKER_IMAGE="${ECR_BASE}/ticketing/worker-svc:${TAG}"

aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_BASE}"
docker build -t "${WAS_IMAGE}" "${WAS_DIR}"
docker push "${WAS_IMAGE}"
docker build -t "${WORKER_IMAGE}" "${WORKER_DIR}"
docker push "${WORKER_IMAGE}"
