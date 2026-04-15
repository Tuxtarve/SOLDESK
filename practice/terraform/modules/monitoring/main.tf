# 1. Prometheus & Grafana (메트릭 수집 및 시각화)
resource "helm_release" "prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

# ✅ 외부 values.yaml 파일을 읽어서 적용한다!
  values = [
    file("${path.module}/values.yaml")
  ]

  # clusterName 처럼 변수 처리가 필요한 것만 set으로 남겨두렴
  set {
    name  = "global.clusterName"
    value = var.cluster_name
  }
 # 🔥 추가 1: CRD 설치 (ServiceMonitor 필수)
  set {
    name  = "crds.enabled"
    value = "true"
  }

  # 🔥 추가 2: 다른 namespace도 수집
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorNamespaceSelector.any"
    value = "true"
  }

  # 🔥 추가 3: label 매칭 (ServiceMonitor 연결 핵심)
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelector.matchLabels.release"
    value = "kube-prometheus-stack"
  }
}



# 2. Loki Stack (로그 수집 및 저장)
# Tempo 대신 Loki를 넣어 효율을 극대화한다!
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = "monitoring"
  
  # 위에서 생성하므로 여기선 create_namespace = false (기본값)
  depends_on = [helm_release.prometheus_stack]

  set {
    name  = "loki.persistence.enabled"
    value = "true"
  }

  set {
    name  = "loki.persistence.size"
    value = "5Gi"
  }

  # Promtail을 켜야 각 노드의 로그를 Loki로 보내준단다
  set {
    name  = "promtail.enabled"
    value = "true"
  }
}

resource "kubernetes_manifest" "worker_monitor" {
  manifest = yamldecode(file("${path.module}/servicemonitor-worker.yaml"))

  depends_on = [
    helm_release.prometheus_stack
  ]
}