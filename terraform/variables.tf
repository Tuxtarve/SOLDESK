variable "env" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type        = string
  description = "AWS region (credentials come from ~/.aws/*)."
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "eks_cluster_name" {
  type        = string
  description = "EKS cluster name."
}

variable "github_repo" {
  description = "GitHub 리포지토리 (owner/repo)"
  type        = string
  default     = "your-org/ticketing"
}

variable "enable_s3_hosting_v2_module" {
  description = "If true, create S3 hosting resources as part of this stack (v2). If false, use external S3_hosting + remote_state (v1)."
  type        = bool
  default     = false
}

variable "s3_hosting_source_dir" {
  description = "Local static frontend directory to upload for v2 module. Example: ../frontend/src (relative to terraform/)."
  type        = string
  default     = "../frontend/src"
}

variable "enable_cloudfront_for_frontend" {
  description = "If true, create CloudFront in front of S3 and route /api/* to ALB (team/prod style). If false, use S3 website URL + api-origin.js(sync) (faster apply/destroy)."
  type        = bool
  default     = false
}

variable "api_origin_domain_name" {
  description = "Ingress ALB DNS hostname (no scheme). Used when CloudFront is enabled."
  type        = string
  default     = null
}

variable "enable_db_schema_init" {
  description = "If true, after RDS is created, apply db-schema/create.sql then db-schema/Insert.sql to the writer endpoint. Requires mysql client where terraform runs."
  type        = bool
  default     = false
}

variable "db_schema_name" {
  description = "Schema(DB) name to initialize (must match SQL if it creates/uses DB)."
  type        = string
  default     = "ticketing"
}

variable "db_init_user" {
  description = "DB user used for schema initialization (writer)."
  type        = string
  default     = "root"
}

variable "ticketing_namespace" {
  description = "Kubernetes namespace where ticketing workloads are deployed."
  type        = string
  default     = "ticketing"
}

variable "ticketing_configmap_name" {
  description = "ConfigMap name that holds DB_NAME and other runtime settings."
  type        = string
  default     = "ticketing-config"
}

variable "worker_deployment_name" {
  description = "Kubernetes Deployment name for the SQS worker service."
  type        = string
  default     = "worker-svc"
}

variable "read_api_deployment_name" {
  description = "Kubernetes Deployment name for read-api."
  type        = string
  default     = "read-api"
}

variable "write_api_deployment_name" {
  description = "Kubernetes Deployment name for write-api."
  type        = string
  default     = "write-api"
}

variable "run_k8s_bootstrap_after_apply" {
  description = <<-EOT
    true: 이 apply 한 번 안에서 kubeconfig → 시크릿 → kubectl apply → (S3+CF끔 시) ALB 기준 api-origin.js 동기화 → 롤아웃까지.
    kubectl/terraform/aws CLI 없는 CI에서는 false.
  EOT
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Docker image tag to deploy for ticketing-was and worker-svc."
  type        = string
  default     = "latest"
}

variable "ecr_repo_ticketing_was" {
  description = "ECR repository path for ticketing-was (without registry). Example: ticketing/ticketing-was"
  type        = string
  default     = "ticketing/ticketing-was"
}

variable "ecr_repo_worker_svc" {
  description = "ECR repository path for worker-svc (without registry). Example: ticketing/worker-svc"
  type        = string
  default     = "ticketing/worker-svc"
}

variable "k8s_ingress_name" {
  description = "Ingress resource name used for api-origin.js sync."
  type        = string
  default     = "ticketing-ingress"
}
