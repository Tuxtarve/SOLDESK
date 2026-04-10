#!/usr/bin/env bash
set -euo pipefail

: "${K8S_NAMESPACE:?K8S_NAMESPACE required}"
: "${DB_HOST:?DB_HOST required}"
: "${DB_USER:?DB_USER required}"
: "${DB_PASSWORD:?DB_PASSWORD required}"
: "${DB_NAME:?DB_NAME required}"
: "${CREATE_SQL:?CREATE_SQL required}"
: "${INSERT_SQL:?INSERT_SQL required}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. Install kubectl and ensure kubeconfig points to the EKS cluster."
  exit 1
fi

if [ ! -f "$CREATE_SQL" ]; then
  echo "create.sql not found at: $CREATE_SQL"
  exit 1
fi
if [ ! -f "$INSERT_SQL" ]; then
  echo "Insert.sql not found at: $INSERT_SQL"
  exit 1
fi

POD_NAME="db-schema-init-$(date +%s)"

echo "=== DB schema init via Kubernetes ==="
echo "Namespace: $K8S_NAMESPACE"
echo "Pod: $POD_NAME"
echo "RDS writer: $DB_HOST"

kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$K8S_NAMESPACE" >/dev/null

cleanup() {
  kubectl -n "$K8S_NAMESPACE" delete pod "$POD_NAME" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# mysql client container (no server) + long sleep
kubectl -n "$K8S_NAMESPACE" run "$POD_NAME" \
  --image=mysql:8 \
  --restart=Never \
  --command -- sh -lc "sleep 3600" >/dev/null

kubectl -n "$K8S_NAMESPACE" wait --for=condition=Ready pod/"$POD_NAME" --timeout=180s

echo "Copying SQL files into pod..."
kubectl -n "$K8S_NAMESPACE" cp "$CREATE_SQL" "$POD_NAME":/tmp/create.sql >/dev/null
kubectl -n "$K8S_NAMESPACE" cp "$INSERT_SQL" "$POD_NAME":/tmp/Insert.sql >/dev/null

echo "Applying DDL (create.sql)..."
kubectl -n "$K8S_NAMESPACE" exec "$POD_NAME" -- sh -lc \
  "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 < /tmp/create.sql"

echo "Applying seed (Insert.sql)..."
kubectl -n "$K8S_NAMESPACE" exec "$POD_NAME" -- sh -lc \
  "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 < /tmp/Insert.sql"

echo "Verifying basic objects..."
kubectl -n "$K8S_NAMESPACE" exec "$POD_NAME" -- sh -lc \
  "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" -e \"SHOW TABLES; SELECT COUNT(*) AS movies_count FROM movies;\" >/dev/null"

echo "=== DB schema init complete ==="

