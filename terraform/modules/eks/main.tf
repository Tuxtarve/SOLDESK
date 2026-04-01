# destroy 시 EKS Ingress/Service 리소스를 먼저 정리하여 ALB Controller가
# 생성한 로드밸런서·타겟그룹·ENI를 제거한 뒤 클러스터를 삭제한다.
# 이 작업이 없으면 ALB가 VPC 서브넷·보안그룹에 남아 VPC destroy가 실패한다.
resource "null_resource" "cleanup_k8s_resources" {
  triggers = {
    cluster_name = var.cluster_name
    region       = var.aws_region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "=== Cleaning up Kubernetes-managed AWS resources before EKS destroy ==="

      # kubeconfig 업데이트 (클러스터가 아직 살아 있는 경우)
      if aws eks describe-cluster --name ${self.triggers.cluster_name} --region ${self.triggers.region} >/dev/null 2>&1; then
        aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} 2>/dev/null || true

        # Ingress 리소스 삭제 → ALB Controller가 ALB/TG 정리
        kubectl delete ingress --all --all-namespaces --timeout=120s 2>/dev/null || true

        # LoadBalancer 타입 Service 삭제 → NLB/CLB 정리
        kubectl delete svc --field-selector spec.type=LoadBalancer --all-namespaces --timeout=120s 2>/dev/null || true

        echo "Waiting 60s for AWS resources to be cleaned up by controllers..."
        sleep 60
      fi

      # 클러스터 접근 불가 시 직접 정리: VPC 내 남은 ELB 삭제
      VPC_ID=$(aws ec2 describe-vpcs --region ${self.triggers.region} \
        --filters "Name=tag:kubernetes.io/cluster/${self.triggers.cluster_name},Values=owned,shared" \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")

      if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
        echo "Cleaning up leftover ELBs in VPC $VPC_ID..."

        # Classic + ALB/NLB 정리
        for LB_ARN in $(aws elbv2 describe-load-balancers --region ${self.triggers.region} \
          --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
          echo "Deleting load balancer: $LB_ARN"
          aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region ${self.triggers.region} 2>/dev/null || true
        done

        # Target Group 정리
        for TG_ARN in $(aws elbv2 describe-target-groups --region ${self.triggers.region} \
          --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
          echo "Deleting target group: $TG_ARN"
          aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region ${self.triggers.region} 2>/dev/null || true
        done

        echo "Waiting 30s for ENIs to detach..."
        sleep 30
      fi

      echo "=== Cleanup complete ==="
    EOT
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

resource "aws_iam_role" "eks_cluster" {
  name               = "ticketing-eks-cluster-role"
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
    null_resource.cleanup_k8s_resources,
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
  name               = "ticketing-eks-node-role"
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

# 워커 노드 그룹 (t3.small × 2 — 앱 서비스 전용)
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ticketing-app-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = ["t3.small"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  update_config { max_unavailable = 1 }

  labels = { role = "app" }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_cni,
    aws_iam_role_policy_attachment.eks_node_ecr,
  ]

  tags = { Name = "ticketing-app-nodes", Environment = var.env }
}

# ALB Controller IAM (Ingress 자동 생성용)
resource "aws_iam_policy" "alb_controller" {
  name   = "ticketing-alb-controller-policy"
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
  name = "ticketing-alb-controller-role"
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
