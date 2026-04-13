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
  # root-level var 경유로 순환 참조 차단 (module.cloudfront → cognito 직접 참조 금지)
  cloudfront_domain = var.frontend_callback_domain
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
  source                    = "./modules/cloudfront"
  env                       = var.env
  frontend_bucket_id        = module.s3.frontend_bucket_id
  frontend_bucket_arn       = module.s3.frontend_bucket_arn
  frontend_domain           = module.s3.frontend_bucket_regional_domain
  waf_acl_arn               = module.waf.waf_acl_arn
  api_gateway_endpoint_host = module.api_gateway.api_endpoint_host

  # destroy 시 CloudFront가 WAF보다 먼저 삭제되도록 보장
  # (WAF가 먼저 삭제되면 CloudFront destroy가 실패)
  depends_on = [module.waf, module.api_gateway]
}

# ── API Gateway (HTTP API + Cognito JWT Authorizer + VPC Link) ────
# CloudFront의 origin으로 사용. Internal ALB와는 VPC Link로 연결
# 첫 apply 시 alb_listener_arn=""이면 API GW 본체만 만들고
# Integration/Route는 두 번째 apply (setup-all.sh가 listener ARN 박은 후)에서 생성
module "api_gateway" {
  source = "./modules/api_gateway"
  env    = var.env
  aws_region = var.aws_region

  vpc_id                      = module.network.vpc_id
  private_subnet_ids          = module.network.private_subnet_ids
  cognito_user_pool_id        = module.cognito.user_pool_id
  cognito_user_pool_client_id = module.cognito.user_pool_client_id
  alb_listener_arn            = var.alb_listener_arn

  depends_on = [module.network, module.cognito]
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

# ── EKS 삭제 후 VPC 고아 리소스 정리 ──────────────────────────────
# Destroy 순서: module.eks → post_eks_vpc_cleanup → module.network
# EKS 삭제 후 K8s 컨트롤러가 남긴 보안그룹·ENI를 제거하여 VPC 삭제 hang 영구 방지
resource "null_resource" "post_eks_vpc_cleanup" {
  triggers = {
    vpc_id = module.network.vpc_id
    region = var.aws_region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "=== Post-EKS VPC cleanup: K8s 고아 리소스 제거 ==="
      VPC_ID="${self.triggers.vpc_id}"
      REGION="${self.triggers.region}"
      [ -z "$VPC_ID" ] && exit 0

      # K8s/EKS가 생성한 보안 그룹 (k8s-*, eks-cluster-sg-*)
      K8S_SGS=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*,eks-cluster-sg-*" \
        --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null)

      if [ -n "$K8S_SGS" ] && [ "$K8S_SGS" != "None" ]; then
        echo "고아 보안 그룹 발견: $K8S_SGS"
        # 1단계: 상호 참조 규칙 제거
        for SG_ID in $K8S_SGS; do
          INGRESS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
            --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
          if [ "$INGRESS" != "[]" ] && [ -n "$INGRESS" ]; then
            aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --ip-permissions "$INGRESS" --region "$REGION" 2>/dev/null || true
          fi
          EGRESS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
          if [ "$EGRESS" != "[]" ] && [ -n "$EGRESS" ]; then
            aws ec2 revoke-security-group-egress --group-id "$SG_ID" --ip-permissions "$EGRESS" --region "$REGION" 2>/dev/null || true
          fi
        done
        # 2단계: 보안 그룹 삭제
        for SG_ID in $K8S_SGS; do
          echo "  삭제: $SG_ID"
          aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
        done
      else
        echo "정리할 고아 보안 그룹 없음"
      fi

      # 고아 ENI 분리 및 삭제
      for ENI_ID in $(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "NetworkInterfaces[?Attachment.DeviceIndex!=\`0\`].NetworkInterfaceId" \
        --output text 2>/dev/null); do
        ATTACH_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
          --network-interface-ids "$ENI_ID" \
          --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null)
        if [ "$ATTACH_ID" != "None" ] && [ -n "$ATTACH_ID" ]; then
          aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region "$REGION" 2>/dev/null || true
        fi
      done
      sleep 10
      for ENI_ID in $(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
        echo "  ENI 삭제: $ENI_ID"
        aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
      done

      echo "=== Post-EKS VPC cleanup 완료 ==="
    EOT
  }
}

module "eks" {
  source            = "./modules/eks"
  env               = var.env
  aws_region        = var.aws_region
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.network.eks_sg_id
  cluster_name      = var.eks_cluster_name
  sqs_queue_arns    = [module.sqs.reservation_queue_arn, module.sqs.reservation_dlq_arn]

  # destroy 순서: module.eks → post_eks_vpc_cleanup → module.network
  depends_on = [module.network, null_resource.post_eks_vpc_cleanup]
}

# Internal ALB DNS lookup (ALB Ingress Controller가 생성한 ALB)
# alb_listener_arn이 채워진 후에만 lookup, 첫 apply 사이클에서는 빈 문자열
data "aws_lb_listener" "ingress" {
  count = var.alb_listener_arn != "" ? 1 : 0
  arn   = var.alb_listener_arn
}

data "aws_lb" "ingress" {
  count = var.alb_listener_arn != "" ? 1 : 0
  arn   = data.aws_lb_listener.ingress[0].load_balancer_arn
}

module "monitoring" {
  source            = "./modules/monitoring"
  env               = var.env
  subnet_id         = module.network.public_subnet_ids[0]
  security_group_id = module.network.monitoring_sg_id
  key_name          = var.key_name
  redis_host        = module.elasticache.redis_endpoint
  slack_webhook_url = var.slack_webhook_url
  alb_dns           = var.alb_listener_arn != "" ? data.aws_lb.ingress[0].dns_name : ""

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

# EKS 노드 → SQS 접근 허용 (reserv-svc, worker-svc 에서 사용)
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
      ]
    }]
  })
}

