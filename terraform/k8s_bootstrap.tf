# 한 번의 apply 안에서: kubeconfig → kubectl → (S3+CF끔 시) Ingress ALB 로 api-origin.js 동기화 → 롤아웃까지. 끝.
# 끄려면: run_k8s_bootstrap_after_apply = false

resource "null_resource" "k8s_bootstrap_after_apply" {
  count = var.run_k8s_bootstrap_after_apply ? 1 : 0

  # 시크릿 스크립트가 terraform output 으로 RDS/ElastiCache/SQS 를 읽으므로 반드시 이 모듈들 이후에 실행.
  # (depends_on 없으면 ElastiCache 생성 전에 bootstrap 이 돌아 redis_endpoint 가 state 에 없을 수 있음)
  depends_on = [
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
    cluster_name                = module.eks.cluster_name
    metrics_server_replicas     = var.eks_metrics_server_replica_count
    kustomization               = filemd5(abspath("${path.root}/../k8s/kustomization.yaml"))
    read_api_deploy_burst       = filemd5(abspath("${path.root}/../k8s/read-api/deployment-burst.yaml"))
    write_api_deploy_burst      = filemd5(abspath("${path.root}/../k8s/write-api/deployment-burst.yaml"))
    worker_deploy_burst         = filemd5(abspath("${path.root}/../k8s/worker-svc/deployment-burst.yaml"))
    read_api_hpa                = filemd5(abspath("${path.root}/../k8s/read-api/hpa.yaml"))
    write_api_hpa               = filemd5(abspath("${path.root}/../k8s/write-api/hpa.yaml"))
    k8s_priorityclass           = filemd5(abspath("${path.root}/../k8s/priorityclass-ticketing.yaml"))
    k8s_pdb                     = filemd5(abspath("${path.root}/../k8s/pdb-user-facing.yaml"))
    keda_triggerauth            = filemd5(abspath("${path.root}/../k8s/keda/triggerauthentication-worker-sqs.yaml"))
    keda_scaledobject_worker    = filemd5(abspath("${path.root}/../k8s/keda/scaledobject-worker-svc-sqs.yaml"))
    post_apply_bootstrap_script = filemd5(abspath("${path.root}/scripts/post_apply_k8s_bootstrap.sh"))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      REPO_ROOT   = abspath("${path.root}/..")
      DB_PASSWORD = var.db_password
      # 같은 apply 중 nested `terraform output`은 state 락·sensitive 출력 때문에 실패할 수 있음 → 모듈 값 직접 전달
      POST_APPLY_RDS_WRITER_ENDPOINT    = nonsensitive(module.rds.writer_endpoint)
      POST_APPLY_REDIS_PRIMARY_ENDPOINT = nonsensitive(module.elasticache.redis_endpoint)
      EKS_CLUSTER_NAME                  = module.eks.cluster_name
      AWS_REGION                        = var.aws_region
      TICKETING_NAMESPACE               = var.ticketing_namespace
      TICKETING_CONFIGMAP_NAME          = var.ticketing_configmap_name
      WORKER_DEPLOYMENT_NAME            = var.worker_deployment_name
      READ_API_DEPLOYMENT_NAME          = var.read_api_deployment_name
      WRITE_API_DEPLOYMENT_NAME         = var.write_api_deployment_name
      K8S_INGRESS_NAME                  = var.k8s_ingress_name
      IMAGE_TAG                         = var.image_tag
      ECR_REPO_TICKETING_WAS            = var.ecr_repo_ticketing_was
      ECR_REPO_WORKER_SVC               = var.ecr_repo_worker_svc
      DB_SCHEMA_NAME                    = var.db_schema_name
      SYNC_S3_ENDPOINTS = (
        var.enable_s3_hosting_v2_module && !var.enable_cloudfront_for_frontend
      ) ? "1" : "0"
      INSTALL_KEDA = var.install_keda ? "1" : "0"
      # EKS metrics-server 애드온은 configuration_values 로 replica 지정 불가 → bootstrap 에서 scale
      METRICS_SERVER_REPLICAS = tostring(var.eks_metrics_server_replica_count)
    }

    command = "tr -d '\\r' < \"${path.root}/scripts/post_apply_k8s_bootstrap.sh\" | bash"
  }
}
