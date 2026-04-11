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

variable "install_keda" {
  description = "true: terraform helm_release 로 KEDA operator 설치. run_k8s_bootstrap 시 kubectl 로 k8s/keda 적용(ScaledObject paused·오토스케일 끔)."
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

# ── 용량(평시 저비용 + 피크·향후 R/O 리플리카 전제) ─────────────────────────
# “100만 동시”는 단일 RDS에 100만 QPS가 아님.
# - 쓰기: SQS FIFO + 회차/상영별 MessageGroupId → 핫 좌석풀은 직렬 커밋, Writer 부하는 (워커 처리량)×(동시에 열린 회차 수)에 가깝다.
# - 읽기: ElastiCache 조회 캐시 + (추가 예정) RDS Read Replica + read-api 수평 확장이 부담을 나눈다.
# - EKS: 노드 max를 넉넉히 두고 평시 desired=1 유지 → Cluster Autoscaler·HPA로 피크 시 Pod/노드 증설.
# Reader 리플리카 리소스는 아직 Terraform에 넣지 않음 — Writer 클래스는 “커밋 전용” 여유만 본다.

variable "rds_writer_instance_class" {
  type        = string
  default     = "db.t3.micro"
  description = <<-EOT
    RDS Writer (MySQL) — SQS 워커의 INSERT/UPDATE/락만. micro는 시드·저트래픽.
    오픈 직전에는 small 등으로 상향 검토. Reader 추가 후에도 Writer는 쓰기만 받는다.
  EOT
}

variable "rds_allocated_storage_gb" {
  type        = number
  default     = 20
  description = "Writer 초기 디스크(GB)."
}

variable "rds_max_allocated_storage_gb" {
  type        = number
  default     = 0
  description = "자동 스토리지 확장 상한(GB). allocated보다 커야 활성화. 0이면 비활성."
}

variable "elasticache_node_type" {
  type        = string
  default     = "cache.t3.micro"
  description = <<-EOT
    단일 노드 ElastiCache (Redis OSS). 조회 JSON + booking 논리 DB 동시 적재.
    캐시 키·회차 수가 늘면 메모리 부족(eviction) 전에 small 등으로 상향.
  EOT
}

variable "eks_app_node_instance_types" {
  type        = list(string)
  default     = ["t3.small"]
  description = "EKS 워커 인스턴스. 피크 시 노드 수만 늘리면 read-api/worker 파드 수용."
}

variable "eks_app_node_desired_size" {
  type        = number
  default     = 2
  description = "평시 desired 노드 수 (Pod 밀도 한도로 1노드가 부족할 때 2 권장)."
}

variable "eks_app_node_min_size" {
  type        = number
  default     = 1
  description = "최소 노드(비용 바닥)."
}

variable "eks_app_node_max_size" {
  type        = number
  default     = 12
  description = <<-EOT
    피크 시 노드 상한 예시: read-api replica·워커·시스템 파드 합산.
    12×t3.small 수준은 “수만~수십만 RPS급 HTTP”까지는 ALB·앱 한도와 별도로 튜닝 필요.
    실제 100만 동시는 CloudFront·정적 분리·캐시 적중률·Reader 추가와 함께 설계한다.
  EOT

  validation {
    condition     = var.eks_app_node_max_size >= var.eks_app_node_desired_size && var.eks_app_node_desired_size >= var.eks_app_node_min_size && var.eks_app_node_min_size >= 1
    error_message = "eks_app_node_max_size >= desired >= min >= 1 이어야 합니다."
  }
}
