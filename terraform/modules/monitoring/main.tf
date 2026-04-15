# Prometheus & Grafana
resource "helm_release" "prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [
    file("${path.module}/values.yaml")
  ]

  set = [
    {
      name  = "global.clusterName"
      value = var.cluster_name
    }
  ]
}

# Loki
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = "monitoring"

  depends_on = [helm_release.prometheus_stack]

  set = [
    {
      name  = "loki.persistence.enabled"
      value = "true"
    },
    {
      name  = "loki.persistence.size"
      value = "5Gi"
    },
    {
      name  = "promtail.enabled"
      value = "true"
    }
  ]
}

#Servicemonitor
resource "kubernetes_manifest" "worker_monitor" {
  manifest = yamldecode(file("${path.module}/servicemonitor-worker.yaml"))

  depends_on = [
    helm_release.prometheus_stack
  ]
}