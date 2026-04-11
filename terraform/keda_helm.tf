# KEDA operator — terraform apply 시 Helm 으로 설치 (apply 호스트에 helm CLI 불필요).
# ScaledObject 등 CR 은 post_apply_k8s_bootstrap.sh 가 kubectl 로 적용(paused 기본).
#
# hashicorp/helm v3+: kubernetes 블록이 아니라 kubernetes = { ... } 객체 형식.

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.15.2"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      serviceAccount = {
        create      = true
        name        = "keda-operator"
        annotations = { "eks.amazonaws.com/role-arn" = module.eks.keda_operator_role_arn }
      }
    })
  ]

  depends_on = [module.eks]
}
