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
    command     = <<-EOT
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
      VPC_ID="${self.triggers.vpc_id}"

      if [ -n "$VPC_ID" ]; then
        echo "Cleaning up leftover ELBs in VPC $VPC_ID..."

        # ALB/NLB 정리
        for LB_ARN in $(aws elbv2 describe-load-balancers --region ${self.triggers.region} \
          --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
          echo "Deleting load balancer: $LB_ARN"
          aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region ${self.triggers.region} 2>/dev/null || true
        done

        # Classic ELB 정리
        for CLB_NAME in $(aws elb describe-load-balancers --region ${self.triggers.region} \
          --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null); do
          echo "Deleting classic LB: $CLB_NAME"
          aws elb delete-load-balancer --load-balancer-name "$CLB_NAME" --region ${self.triggers.region} 2>/dev/null || true
        done

        # Target Group 정리
        for TG_ARN in $(aws elbv2 describe-target-groups --region ${self.triggers.region} \
          --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
          echo "Deleting target group: $TG_ARN"
          aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region ${self.triggers.region} 2>/dev/null || true
        done

        echo "Waiting 30s for ENIs to detach..."
        sleep 30

        # EIP 해제 (IGW detach 차단 원인 — "mapped public address(es)")
        echo "Releasing Elastic IPs in VPC $VPC_ID..."
        for ALLOC_ID in $(aws ec2 describe-addresses --region ${self.triggers.region} \
          --filters "Name=domain,Values=vpc" \
          --query "Addresses[?NetworkInterfaceId!=null].{A:AllocationId,N:NetworkInterfaceId}" \
          --output text 2>/dev/null | while read AID NID; do
            # 이 EIP가 VPC 내 ENI에 연결되었는지 확인
            ENI_VPC=$(aws ec2 describe-network-interfaces --region ${self.triggers.region} \
              --network-interface-ids "$NID" \
              --query 'NetworkInterfaces[0].VpcId' --output text 2>/dev/null)
            if [ "$ENI_VPC" = "$VPC_ID" ]; then echo "$AID"; fi
          done); do
          echo "Disassociating and releasing EIP: $ALLOC_ID"
          ASSOC_ID=$(aws ec2 describe-addresses --region ${self.triggers.region} \
            --allocation-ids "$ALLOC_ID" \
            --query 'Addresses[0].AssociationId' --output text 2>/dev/null)
          if [ "$ASSOC_ID" != "None" ] && [ -n "$ASSOC_ID" ]; then
            aws ec2 disassociate-address --association-id "$ASSOC_ID" --region ${self.triggers.region} 2>/dev/null || true
          fi
          aws ec2 release-address --allocation-id "$ALLOC_ID" --region ${self.triggers.region} 2>/dev/null || true
        done

        # 연결되지 않은(미사용) EIP도 정리
        for ALLOC_ID in $(aws ec2 describe-addresses --region ${self.triggers.region} \
          --filters "Name=domain,Values=vpc" \
          --query "Addresses[?AssociationId==null].AllocationId" --output text 2>/dev/null); do
          echo "Releasing unused EIP: $ALLOC_ID"
          aws ec2 release-address --allocation-id "$ALLOC_ID" --region ${self.triggers.region} 2>/dev/null || true
        done

        # ELB/k8s 잔여 ENI 만 (network 모듈과 동일 필터) — RDS/기타 available ENI 건드리지 않음
        echo "Cleaning up leftover ENIs (aws-K8S / ELB) in VPC $VPC_ID..."
        for ENI_ID in $(aws ec2 describe-network-interfaces --region ${self.triggers.region} \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-') || contains(Description, 'ELB')].NetworkInterfaceId" \
          --output text 2>/dev/null); do
          [ -n "$ENI_ID" ] || continue
          ATTACH_ID=$(aws ec2 describe-network-interfaces --region ${self.triggers.region} \
            --network-interface-ids "$ENI_ID" \
            --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
          if [ "$ATTACH_ID" != "None" ] && [ -n "$ATTACH_ID" ]; then
            echo "Detaching ENI: $ENI_ID"
            aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region ${self.triggers.region} 2>/dev/null || true
          fi
        done
        sleep 15
        for ENI_ID in $(aws ec2 describe-network-interfaces --region ${self.triggers.region} \
          --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
          --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-') || contains(Description, 'ELB')].NetworkInterfaceId" \
          --output text 2>/dev/null); do
          [ -n "$ENI_ID" ] || continue
          echo "Deleting ENI: $ENI_ID"
          aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region ${self.triggers.region} 2>/dev/null || true
        done

        # k8s/ALB/EKS 가 만든 SG 만 정리. network 모듈 Terraform SG(prod-* 등)는 절대 삭제하지 않음
        # (이전: default 제외 전부 삭제 → TF managed SG 가 먼저 지워져 destroy 시 read SG 오류·2회 destroy 유발)
        echo "Cleaning up k8s-generated security groups in VPC $VPC_ID (skip Terraform SGs)..."
        TF_SG_NAMES="prod-monitoring-sg prod-eks-sg prod-rds-sg Cache_SG default"
        for SG_ID in $(aws ec2 describe-security-groups --region ${self.triggers.region} \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --query "SecurityGroups[].GroupId" --output text 2>/dev/null); do
          [ -n "$SG_ID" ] || continue
          SG_NAME=$(aws ec2 describe-security-groups --region ${self.triggers.region} --group-ids "$SG_ID" \
            --query "SecurityGroups[0].GroupName" --output text 2>/dev/null || true)
          case " $TF_SG_NAMES " in
            *" $SG_NAME "*) continue ;;
          esac
          # 클러스터/노드가 아직 있음 — eks-cluster-sg-* 는 여기서 지우면 안 됨(ALB 등 k8s-* 만)
          if [[ "$SG_NAME" =~ ^k8s- ]]; then
            echo "Revoking rules for k8s SG: $SG_ID ($SG_NAME)"
            aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --region ${self.triggers.region} \
              --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region ${self.triggers.region} \
              --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" 2>/dev/null || true
            aws ec2 revoke-security-group-egress --group-id "$SG_ID" --region ${self.triggers.region} \
              --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region ${self.triggers.region} \
              --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" 2>/dev/null || true
            echo "Deleting k8s SG: $SG_ID ($SG_NAME)"
            aws ec2 delete-security-group --group-id "$SG_ID" --region ${self.triggers.region} 2>/dev/null || true
          fi
        done
      fi

      echo "=== Cleanup complete ==="
    EOT
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
    command     = <<-EOT
      set -euo pipefail
      REGION="${self.triggers.region}"
      VPC_ID="${self.triggers.vpc_id}"

      echo "=== Post-EKS cleanup: deleting leftover aws-k8s ENIs in VPC $VPC_ID ==="

      if [ -z "$VPC_ID" ]; then
        echo "VPC_ID empty; skipping."
        exit 0
      fi

      # 노드그룹 종료 직후 ENI가 늦게 available로 바뀌는 경우를 고려해 짧게 재시도
      for i in 1 2 3 4 5; do
        ENIS=$(aws ec2 describe-network-interfaces --region "$REGION" \
          --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
          --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-')].NetworkInterfaceId" \
          --output text 2>/dev/null || true)

        if [ -z "$ENIS" ]; then
          echo "No aws-k8s ENIs found (attempt $i/5)."
          sleep 10
          continue
        fi

        for ENI_ID in $ENIS; do
          echo "Deleting ENI: $ENI_ID"
          aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
        done

        sleep 10
      done

      echo "=== Post-EKS cleanup complete ==="
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

# 워커 노드 그룹 (테스트/실행 가능 최소 안정)
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-app-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = var.subnet_ids
  # 최소 비용 구성: (Ingress/ALB 요구사항 고려) 노드 2대 유지 + 인스턴스는 t3.small
  instance_types = ["t3.small"]
  ami_type       = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
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
