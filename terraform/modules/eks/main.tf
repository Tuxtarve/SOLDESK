# destroy 순서: 이 null_resource 먼저 삭제(→ cleanup 실행) → 노드그룹 → EKS 클러스터
# depends_on 으로 EKS/노드가 살아 있는 동안 kubectl 정리가 수행되도록 보장한다.
# ALB Controller가 만든 로드밸런서·타겟그룹·ENI를 제거해야 VPC destroy가 성공한다.
# 아래 sleep 은 잔여 ENI/ALB 때문에 subnet 삭제가 막히는 걸 줄이기 위함 — 줄이면 destroy 실패율이 올라갈 수 있음.
resource "null_resource" "cleanup_k8s_resources" {
  triggers = {
    cluster_name = var.cluster_name
    region       = var.aws_region
    vpc_id       = var.vpc_id
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_eks_node_group.app,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    when        = destroy
    environment = {
      EKS_CLUSTER_NAME = self.triggers.cluster_name
      EKS_REGION       = self.triggers.region
      EKS_VPC_ID       = self.triggers.vpc_id
    }
    # HGFS/Windows 등에서 .tf 가 CRLF 일 때 heredoc 이 깨지므로 스크립트 파일 + 실행 시 CR 제거
    command = "tr -d '\\r' < \"${path.module}/scripts/cleanup_k8s_resources_on_destroy.sh\" | bash"
  }
}

# NOTE:
# - 위 cleanup_k8s_resources 는 "EKS/노드가 살아있는 동안" Ingress/SVC 등을 먼저 내리기 위한 선행 정리다.
# - 하지만 실제로는 노드그룹 종료 후에 aws-k8s ENI가 'available' 상태로 남는 타이밍이 발생할 수 있다.
# - 아래 cleanup_vpc_leftovers_post 는 노드그룹/클러스터 삭제 "후"에 한 번 더 ENI 잔재를 지워서
#   subnet 삭제가 막히는 상황을 줄인다.
resource "null_resource" "cleanup_vpc_leftovers_post" {
  triggers = {
    region = var.aws_region
    vpc_id = var.vpc_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    when        = destroy
    environment = {
      EKS_POST_REGION = self.triggers.region
      EKS_POST_VPC_ID = self.triggers.vpc_id
    }
    command = "tr -d '\\r' < \"${path.module}/scripts/cleanup_vpc_enis_post_eks_destroy.sh\" | bash"
  }
}

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

locals {
  # IAM Role/Policy names have length limits; keep stable but avoid hardcoding.
  name_prefix = substr(replace(var.cluster_name, "/[^a-zA-Z0-9+=,.@_-]/", "-"), 0, 32)
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${local.name_prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    null_resource.cleanup_vpc_leftovers_post,
  ]
  tags = { Name = var.cluster_name, Environment = var.env }
}

# 노드 그룹 IAM
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${local.name_prefix}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# 워커 노드 그룹 — 평시 min/desired 로 비용 최소, max 로 피크 시 증설 여유(Cluster Autoscaler 권장)
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-app-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.app_node_instance_types
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.app_node_desired_size
    min_size     = var.app_node_min_size
    max_size     = var.app_node_max_size
  }

  update_config { max_unavailable = 1 }

  labels = { role = "app" }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_cni,
    aws_iam_role_policy_attachment.eks_node_ecr,
    null_resource.cleanup_vpc_leftovers_post,
  ]

  tags = { Name = "${local.name_prefix}-app-nodes", Environment = var.env }
}

# ALB Controller IAM (Ingress 자동 생성용)
resource "aws_iam_policy" "alb_controller" {
  name   = "${local.name_prefix}-alb-controller-policy"
  policy = file("${path.module}/alb-controller-policy.json")
}

data "aws_caller_identity" "current" {}

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
}

resource "aws_iam_role" "alb_controller" {
  name = "${local.name_prefix}-alb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# Cluster Autoscaler IAM (노드 자동 스케일링용)
resource "aws_iam_policy" "cluster_autoscaler" {
  name = "${local.name_prefix}-cluster-autoscaler-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeInstanceTypes",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${local.name_prefix}-cluster-autoscaler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# SQS 접근용 IRSA (reserv-svc, worker-svc 공용)
resource "aws_iam_role" "sqs_access" {
  name = "${local.name_prefix}-sqs-access-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:ticketing:sqs-access-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "sqs_access" {
  name = "${local.name_prefix}-sqs-access-policy"
  role = aws_iam_role.sqs_access.name
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
      Resource = var.sqs_queue_arns
    }]
  })
}
