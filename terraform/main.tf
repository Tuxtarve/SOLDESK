terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.aws_region
}

# CloudFront용 WAF는 반드시 us-east-1에 생성해야 함
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "network" {
  source           = "./modules/network"
  env              = var.env
  aws_region       = var.aws_region
  eks_cluster_name = var.eks_cluster_name
}

module "cognito" {
  source                = "./modules/cognito"
  env                   = var.env
  app_name              = var.app_name
  cognito_domain_prefix = var.cognito_domain_prefix
  cloudfront_domain     = module.cloudfront.cloudfront_domain
}

module "s3" {
  source      = "./modules/s3"
  env         = var.env
  aws_account = data.aws_caller_identity.current.account_id
}

module "waf" {
  source = "./modules/waf"
  env    = var.env

  providers = {
    aws = aws.us_east_1
  }
}

module "cloudfront" {
  source               = "./modules/cloudfront"
  env                  = var.env
  frontend_bucket_id   = module.s3.frontend_bucket_id
  frontend_bucket_arn  = module.s3.frontend_bucket_arn
  frontend_domain      = module.s3.frontend_bucket_regional_domain
  waf_acl_arn          = module.waf.waf_acl_arn
  alb_dns_name         = var.alb_dns_name

  # destroy 시 CloudFront가 WAF보다 먼저 삭제되도록 보장
  # (WAF가 먼저 삭제되면 CloudFront destroy가 실패)
  depends_on = [module.waf]
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

  # destroy 시 ElastiCache가 네트워크(SG/서브넷)보다 먼저 삭제되도록 보장
  depends_on = [module.network]
}

module "rds" {
  source            = "./modules/rds"
  env               = var.env
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.rds_sg_id
  db_password       = var.db_password

  # destroy 시 RDS가 네트워크(SG/서브넷)보다 먼저 삭제되도록 보장
  depends_on = [module.network]
}

module "eks" {
  source            = "./modules/eks"
  env               = var.env
  aws_region        = var.aws_region
  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.network.eks_sg_id
  cluster_name      = var.eks_cluster_name

  # destroy 시 EKS가 네트워크(SG/서브넷)보다 먼저 삭제되도록 보장
  depends_on = [module.network]
}

module "monitoring" {
  source            = "./modules/monitoring"
  env               = var.env
  subnet_id         = module.network.public_subnet_ids[0]
  security_group_id = module.network.monitoring_sg_id
  key_name          = var.key_name
  redis_host        = module.elasticache.redis_endpoint

  # destroy 시 EC2가 네트워크(SG/서브넷)보다 먼저 삭제되도록 보장
  depends_on = [module.network, module.elasticache]
}

module "cicd" {
  source          = "./modules/cicd"
  env             = var.env
  aws_region      = var.aws_region
  github_repo     = var.github_repo
  cluster_name    = module.eks.cluster_name
  s3_frontend_arn = module.s3.frontend_bucket_arn
}

data "aws_caller_identity" "current" {}

# EKS 노드가 실제 사용하는 클러스터 SG → RDS/Redis 접근 허용
# (EKS는 vpc_config.security_group_ids 외에 자체 클러스터 SG를 자동 생성하여 노드에 할당)
resource "aws_security_group_rule" "rds_from_eks_cluster_sg" {
  type                     = "ingress"
  description              = "MySQL from EKS cluster SG"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = module.network.rds_sg_id
  source_security_group_id = module.eks.cluster_security_group_id
}

resource "aws_security_group_rule" "redis_from_eks_cluster_sg" {
  type                     = "ingress"
  description              = "Redis from EKS cluster SG"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = module.network.redis_sg_id
  source_security_group_id = module.eks.cluster_security_group_id
}

