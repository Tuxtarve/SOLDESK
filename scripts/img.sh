#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
AWS_REGION="${AWS_REGION:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"

# terraform console 로 var 읽기 (init + tfvars 로드됨). 실패 시 빈 문자열.
_tf_var() {
  local key="$1"
  local line
  line="$(printf 'var.%s\n' "${key}" | terraform -chdir="${TF_DIR}" console 2>/dev/null | head -n1 || true)"
  line="${line//$'\r'/}"
  if [[ -z "${line}" || "${line}" == *Error* ]]; then
    return 1
  fi
  if [[ "${line}" == \"*\" ]]; then
    line="${line#\"}"
    line="${line%\"}"
  fi
  printf '%s\n' "${line}"
}

if [ -z "${ACCOUNT_ID}" ]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

if [ -z "${AWS_REGION}" ]; then
  AWS_REGION="$(_tf_var aws_region 2>/dev/null || true)"
fi
if [ -z "${AWS_REGION}" ]; then
  AWS_REGION="$(terraform -chdir="${TF_DIR}" output -raw aws_region 2>/dev/null || true)"
fi
if [ -z "${AWS_REGION}" ]; then
  echo "ERROR: AWS_REGION is required (set env, or run terraform init so tfvars aws_region is readable via console, or use output after apply)" >&2
  exit 1
fi

# 태그: 환경변수 TAG 우선, 없으면 tfvars 의 image_tag, 마지막 latest
if [ -z "${TAG:-}" ]; then
  TAG="$(_tf_var image_tag 2>/dev/null || true)"
  TAG="${TAG:-latest}"
fi

# 레포 경로: 환경변수 우선, 없으면 tfvars 의 ecr_repo_*, 마지막 terraform/variables.tf 기본값과 동일
REPO_WAS="${ECR_REPO_TICKETING_WAS:-}"
if [ -z "${REPO_WAS}" ]; then
  REPO_WAS="$(_tf_var ecr_repo_ticketing_was 2>/dev/null || true)"
  REPO_WAS="${REPO_WAS:-ticketing/ticketing-was}"
fi

REPO_WORKER="${ECR_REPO_WORKER_SVC:-}"
if [ -z "${REPO_WORKER}" ]; then
  REPO_WORKER="$(_tf_var ecr_repo_worker_svc 2>/dev/null || true)"
  REPO_WORKER="${REPO_WORKER:-ticketing/worker-svc}"
fi

ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
WAS_DIR="${ROOT_DIR}/services/ticketing-was"
WORKER_DIR="${ROOT_DIR}/services/worker-svc"
WAS_IMAGE="${ECR_BASE}/${REPO_WAS}:${TAG}"
WORKER_IMAGE="${ECR_BASE}/${REPO_WORKER}:${TAG}"

aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_BASE}"
docker build -t "${WAS_IMAGE}" "${WAS_DIR}"
docker push "${WAS_IMAGE}"
docker build -t "${WORKER_IMAGE}" "${WORKER_DIR}"
docker push "${WORKER_IMAGE}"
