#!/usr/bin/env bash
set -euo pipefail

# Run the same steps as terraform output zzzzz, but reliably on Linux even
# when scripts were edited on Windows (CRLF). No extra flags needed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/scripts/normalize-line-endings.sh" >/dev/null

cd "$ROOT_DIR/terraform"

bash "$ROOT_DIR/k8s/scripts/apply-secrets-from-terraform.sh"
kubectl apply -k "$ROOT_DIR/k8s"
bash "$ROOT_DIR/k8s/scripts/sync-s3-endpoints-from-ingress.sh"
kubectl -n ticketing patch cm ticketing-config --type merge -p '{"data":{"DB_NAME":"ticketing"}}'
kubectl -n ticketing rollout restart deploy/worker-svc
kubectl -n ticketing rollout restart deploy/read-api

