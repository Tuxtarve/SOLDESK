#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Installing kube-prometheus-stack ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# Apply PrometheusRule CRD (alert rules)
kubectl apply -f "$ROOT_DIR/monitoring/prometheus-rules.yaml"

# Apply Grafana dashboard ConfigMap
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT_DIR/monitoring/k8s/grafana-dashboards-configmap.yaml"

# kube-prometheus-stack
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values "$ROOT_DIR/monitoring/values-kube-prometheus-stack.yaml" \
  --wait --timeout 10m

echo "=== Installing Loki ==="
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values "$ROOT_DIR/monitoring/values-loki.yaml" \
  --wait --timeout 5m

echo "=== Installing Promtail ==="
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --set "config.clients[0].url=http://loki:3100/loki/api/v1/push" \
  --wait --timeout 5m

# Grafana ALB Ingress
kubectl apply -f "$ROOT_DIR/monitoring/k8s/grafana-ingress.yaml"

echo ""
echo "=== Monitoring stack installed ==="
echo "Grafana : kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo "          or via ALB at /grafana  (root / soldesk1.)"
echo "Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
