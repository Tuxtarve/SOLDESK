#!/usr/bin/env bash
set -euo pipefail

# Creates/updates the Kubernetes Secret `ticketing-secrets` from Terraform outputs.
# This file contains NO secrets; it fetches endpoints from Terraform and reads DB password from your input/env.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"

NAMESPACE="${NAMESPACE:-ticketing}"
SECRET_NAME="${SECRET_NAME:-ticketing-secrets}"

DB_PASSWORD="${DB_PASSWORD:-}"
if [ -z "${DB_PASSWORD}" ]; then
  echo "ERROR: DB_PASSWORD is required (export DB_PASSWORD=...)" >&2
  exit 1
fi

DB_WRITER="$(terraform -chdir="$TF_DIR" output -raw rds_writer_endpoint)"
REDIS_EP="$(terraform -chdir="$TF_DIR" output -raw redis_endpoint)"
SQS_URL="$(terraform -chdir="$TF_DIR" output -raw sqs_queue_url)"

kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal=DB_WRITER_HOST="$DB_WRITER" \
  --from-literal=DB_READER_HOST="$DB_WRITER" \
  --from-literal=DB_USER="root" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=REDIS_HOST="$REDIS_EP" \
  --from-literal=SQS_QUEUE_URL="$SQS_URL" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

echo "Applied secret: $NAMESPACE/$SECRET_NAME"

