terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.aws_region
}

locals {
  db_schema_create_sql_path = abspath("${path.root}/../db-schema/create.sql")
  db_schema_insert_sql_path = abspath("${path.root}/../db-schema/Insert.sql")
}

# local-exec 가 쓰는 aws/kubectl/helm 이 없으면 이 스크립트가 Linux·macOS 에서 자동 설치를 시도한다(네트워크·sudo/root 필요할 수 있음).
data "external" "terraform_host_exec_clis" {
  # 공유 폴더/Windows 편집기 CRLF 로 bash 가 깨지지 않게 다른 local-exec 과 동일하게 CR 제거.
  program = ["bash", "-c", "tr -d '\\r' < \"${path.module}/scripts/verify_terraform_host_cli.sh\" | bash"]
}

module "network" {
  source           = "./modules/network"
  env              = var.env
  aws_region       = var.aws_region
  eks_cluster_name = var.eks_cluster_name
}

module "sqs" {
  source = "./modules/sqs"
  env    = var.env
}

module "elasticache" {
  source            = "./modules/elasticache"
  env               = var.env
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.redis_sg_id
  node_type         = var.elasticache_node_type
  depends_on        = [module.network]
}

module "rds" {
  source                = "./modules/rds"
  env                   = var.env
  subnet_ids            = module.network.private_subnet_ids
  security_group_id     = module.network.rds_sg_id
  db_password           = var.db_password
  writer_instance_class = var.rds_writer_instance_class
  allocated_storage     = var.rds_allocated_storage_gb
  max_allocated_storage = var.rds_max_allocated_storage_gb
  depends_on            = [module.network]
}

resource "null_resource" "db_schema_init" {
  count = var.enable_db_schema_init ? 1 : 0

  triggers = {
    writer_endpoint = module.rds.writer_endpoint
    create_md5      = filemd5(local.db_schema_create_sql_path)
    insert_md5      = filemd5(local.db_schema_insert_sql_path)
    db_name         = var.db_schema_name
    db_user         = var.db_init_user
  }

  # RDS는 private subnet + SG가 EKS만 허용이므로,
  # 스키마/시드는 EKS 내부에서(mysql:8 임시 Pod) 실행한다.
  depends_on = [
    data.external.terraform_host_exec_clis,
    module.rds,
    module.eks,
    aws_security_group_rule.rds_from_eks_cluster_sg,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      DB_HOST          = module.rds.writer_endpoint
      DB_USER          = var.db_init_user
      DB_PASSWORD      = var.db_password
      DB_NAME          = var.db_schema_name
      CREATE_SQL       = local.db_schema_create_sql_path
      INSERT_SQL       = local.db_schema_insert_sql_path
      K8S_NAMESPACE    = var.ticketing_namespace
      EKS_CLUSTER_NAME = module.eks.cluster_name
      AWS_REGION       = var.aws_region
    }
    command = "tr -d '\\r' < \"${path.root}/scripts/init_db_schema_via_k8s.sh\" | bash"
  }
}

module "eks" {
  source                  = "./modules/eks"
  env                     = var.env
  aws_region              = var.aws_region
  vpc_id                  = module.network.vpc_id
  subnet_ids              = module.network.public_subnet_ids
  security_group_id       = module.network.eks_sg_id
  cluster_name            = var.eks_cluster_name
  sqs_queue_arns = [
    module.sqs.reservation_queue_arn,
    module.sqs.reservation_dlq_arn,
    module.sqs.reservation_interactive_queue_arn,
    module.sqs.reservation_interactive_dlq_arn,
  ]
  app_node_instance_types = var.eks_app_node_instance_types
  app_node_desired_size   = var.eks_app_node_desired_size
  app_node_min_size       = var.eks_app_node_min_size
  app_node_max_size       = var.eks_app_node_max_size
  depends_on              = [module.network]
}

module "s3_hosting_v2" {
  source     = "./modules/s3_hosting"
  aws_region = var.aws_region

  enabled    = var.enable_s3_hosting_v2_module
  source_dir = var.s3_hosting_source_dir

  # Optional (team/prod): CloudFront + S3 + /api/* → ALB. Off: S3 website + api-origin.js(sync) → ALB.
  cloudfront_enabled     = var.enable_cloudfront_for_frontend
  api_origin_domain_name = var.api_origin_domain_name
}

data "aws_caller_identity" "current" {}

# EKS 노드 → RDS 접근 허용
resource "aws_security_group_rule" "rds_from_eks_cluster_sg" {
  type                     = "ingress"
  description              = "MySQL from EKS cluster SG"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = module.network.rds_sg_id
  source_security_group_id = module.eks.cluster_security_group_id
}

# EKS 노드 → Redis 접근 허용
resource "aws_security_group_rule" "redis_from_eks_cluster_sg" {
  type                     = "ingress"
  description              = "Redis from EKS cluster SG"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = module.network.redis_sg_id
  source_security_group_id = module.eks.cluster_security_group_id
}

# EKS 노드 → SQS 접근 허용
resource "aws_iam_role_policy" "eks_node_sqs" {
  name = "ticketing-eks-node-sqs"
  role = module.eks.node_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = [
        module.sqs.reservation_queue_arn,
        module.sqs.reservation_dlq_arn,
        module.sqs.reservation_interactive_queue_arn,
        module.sqs.reservation_interactive_dlq_arn,
      ]
    }]
  })
}
