# 한 번의 apply 안에서: kubeconfig → kubectl → (S3+CF끔 시) Ingress ALB 로 api-origin.js 동기화 → 롤아웃까지. 끝.
# 끄려면: run_k8s_bootstrap_after_apply = false

resource "null_resource" "k8s_bootstrap_after_apply" {
  count = var.run_k8s_bootstrap_after_apply ? 1 : 0

  # module.eks 는 triggers / environment 에서 이미 암시적 의존.
  # s3 모듈은 스크립트가 terraform output 으로만 버킷을 읽어 암시적 의존이 없으므로 명시 유지.
  depends_on = [
    data.external.terraform_host_exec_clis,
    null_resource.install_aws_load_balancer_controller,
    module.s3_hosting_v2,
    null_resource.db_schema_init,
  ]

  triggers = {
    cluster_name  = module.eks.cluster_name
    kustomization = filemd5(abspath("${path.root}/../k8s/kustomization.yaml"))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      REPO_ROOT                 = abspath("${path.root}/..")
      DB_PASSWORD               = var.db_password
      EKS_CLUSTER_NAME          = module.eks.cluster_name
      AWS_REGION                = var.aws_region
      TICKETING_NAMESPACE       = var.ticketing_namespace
      TICKETING_CONFIGMAP_NAME  = var.ticketing_configmap_name
      WORKER_DEPLOYMENT_NAME    = var.worker_deployment_name
      READ_API_DEPLOYMENT_NAME  = var.read_api_deployment_name
      WRITE_API_DEPLOYMENT_NAME = var.write_api_deployment_name
      K8S_INGRESS_NAME          = var.k8s_ingress_name
      IMAGE_TAG                 = var.image_tag
      ECR_REPO_TICKETING_WAS    = var.ecr_repo_ticketing_was
      ECR_REPO_WORKER_SVC       = var.ecr_repo_worker_svc
      DB_SCHEMA_NAME            = var.db_schema_name
      SYNC_S3_ENDPOINTS = (
        var.enable_s3_hosting_v2_module && !var.enable_cloudfront_for_frontend
      ) ? "1" : "0"
    }

    command = "tr -d '\\r' < \"${path.root}/scripts/post_apply_k8s_bootstrap.sh\" | bash"
  }
}
