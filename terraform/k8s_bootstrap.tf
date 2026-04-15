resource "null_resource" "k8s_bootstrap_after_apply" {
  count = var.run_k8s_bootstrap_after_apply ? 1 : 0

  depends_on = [
    kubernetes_namespace.ticketing,   # ⭐ 추가 (핵심)

    data.external.terraform_host_exec_clis,
    null_resource.install_aws_load_balancer_controller,
    module.s3_hosting_v2,
    null_resource.db_schema_init,
    module.rds,
    module.elasticache,
    module.sqs,
    helm_release.keda,
  ]

  triggers = {
    cluster_name        = module.eks.cluster_name
    kustomization       = filemd5(abspath("${path.root}/../k8s/kustomization.yaml"))
    k8s_priorityclass   = filemd5(abspath("${path.root}/../k8s/priorityclass-ticketing.yaml"))
    k8s_pdb             = filemd5(abspath("${path.root}/../k8s/pdb-user-facing.yaml"))
    keda_triggerauth    = filemd5(abspath("${path.root}/../k8s/keda/triggerauthentication-worker-sqs.yaml"))
    post_apply_bootstrap_script = filemd5(abspath("${path.root}/scripts/post_apply_k8s_bootstrap.sh"))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      REPO_ROOT                 = abspath("${path.root}/..")
      DB_PASSWORD               = var.db_password

      POST_APPLY_RDS_WRITER_ENDPOINT     = nonsensitive(module.rds.writer_endpoint)
      POST_APPLY_REDIS_PRIMARY_ENDPOINT  = nonsensitive(module.elasticache.redis_endpoint)
      POST_APPLY_SQS_QUEUE_URL                    = module.sqs.reservation_queue_url
      POST_APPLY_SQS_INTERACTIVE_QUEUE_URL        = module.sqs.reservation_interactive_queue_url

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

      INSTALL_KEDA = var.install_keda ? "1" : "0"
    }

    command = "tr -d '\\r' < \"${path.root}/scripts/post_apply_k8s_bootstrap.sh\" | bash"
  }
}