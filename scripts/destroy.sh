#!/usr/bin/env bash
# terraform destroy 래퍼 스크립트
# EKS/ALB Controller가 Terraform 외부에서 생성한 리소스(EIP, ELB, TG, ENI, SG)를
# 자동 감지·정리하여 VPC/IGW/Subnet 삭제 실패를 영구적으로 방지한다.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"

MAX_RETRIES=4
REGION=$(terraform output -raw aws_region 2>/dev/null || echo "ap-northeast-2")

# ── VPC ID 확인 ──────────────────────────────────────────────────
get_vpc_id() {
  # 1순위: terraform state
  local vpc_id
  vpc_id=$(terraform state show 'module.network.aws_vpc.main' 2>/dev/null \
    | grep '^\s*id\s*=' | head -1 | sed 's/.*= *"//;s/".*//')
  if [ -n "$vpc_id" ]; then echo "$vpc_id"; return; fi

  # 2순위: 태그로 검색
  vpc_id=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=Public_VPC" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
  if [ "$vpc_id" != "None" ] && [ -n "$vpc_id" ]; then echo "$vpc_id"; return; fi

  echo ""
}

# ── VPC 내 모든 외부 생성 리소스 정리 ────────────────────────────
cleanup_vpc() {
  local vpc_id="$1"
  if [ -z "$vpc_id" ]; then
    echo "[cleanup] VPC를 찾을 수 없습니다. 건너뜁니다."
    return 0
  fi
  echo "============================================="
  echo " VPC 정리 시작: $vpc_id"
  echo "============================================="

  # ① EIP 해제 — IGW detach 차단의 근본 원인
  echo ">> [1/6] Elastic IP 해제"
  aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=domain,Values=vpc" \
    --query 'Addresses[*].[AllocationId,AssociationId,NetworkInterfaceId]' \
    --output text 2>/dev/null | while read -r ALLOC_ID ASSOC_ID NID; do
    [ -z "$ALLOC_ID" ] && continue
    # VPC 내 ENI에 연결된 EIP만 대상
    if [ "$NID" != "None" ] && [ -n "$NID" ]; then
      ENI_VPC=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --network-interface-ids "$NID" \
        --query 'NetworkInterfaces[0].VpcId' --output text 2>/dev/null)
      [ "$ENI_VPC" != "$vpc_id" ] && continue
    fi
    if [ "$ASSOC_ID" != "None" ] && [ -n "$ASSOC_ID" ]; then
      echo "   disassociate $ALLOC_ID ($ASSOC_ID)"
      aws ec2 disassociate-address --association-id "$ASSOC_ID" --region "$REGION" 2>/dev/null || true
    fi
    echo "   release $ALLOC_ID"
    aws ec2 release-address --allocation-id "$ALLOC_ID" --region "$REGION" 2>/dev/null || true
  done

  # ② ALB / NLB 삭제
  echo ">> [2/6] ALB/NLB 삭제"
  for LB_ARN in $(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "   delete $LB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region "$REGION" 2>/dev/null || true
  done

  # ③ Classic ELB 삭제
  echo ">> [3/6] Classic ELB 삭제"
  for CLB in $(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$vpc_id'].LoadBalancerName" --output text 2>/dev/null); do
    echo "   delete $CLB"
    aws elb delete-load-balancer --load-balancer-name "$CLB" --region "$REGION" 2>/dev/null || true
  done

  # ④ Target Group 삭제
  echo ">> [4/6] Target Group 삭제"
  for TG_ARN in $(aws elbv2 describe-target-groups --region "$REGION" \
    --query "TargetGroups[?VpcId=='$vpc_id'].TargetGroupArn" --output text 2>/dev/null); do
    echo "   delete $TG_ARN"
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION" 2>/dev/null || true
  done

  # LB 삭제 후 ENI 해제 대기
  echo "   (ENI 해제 대기 20초)"
  sleep 20

  # ⑤ ENI 분리 → 삭제 (프라이머리 ENI 제외)
  echo ">> [5/6] ENI 분리 및 삭제"
  for ENI_ID in $(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'NetworkInterfaces[?Attachment.DeviceIndex!=`0` || !Attachment].NetworkInterfaceId' \
    --output text 2>/dev/null); do
    ATTACH_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
      --network-interface-ids "$ENI_ID" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null)
    if [ "$ATTACH_ID" != "None" ] && [ -n "$ATTACH_ID" ]; then
      echo "   detach $ENI_ID"
      aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region "$REGION" 2>/dev/null || true
    fi
  done
  sleep 10
  for ENI_ID in $(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=status,Values=available" \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
    echo "   delete $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
  done

  # ⑥ k8s 생성 보안그룹 정리 (상호 참조 규칙 → SG 삭제)
  echo ">> [6/6] non-default 보안그룹 전체 정리"
  K8S_SGS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null)
  for SG_ID in $K8S_SGS; do
    echo "   revoke rules $SG_ID"
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
  for SG_ID in $K8S_SGS; do
    echo "   delete $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
  done

  echo "============================================="
  echo " VPC 정리 완료"
  echo "============================================="
}

# ── 메인 ─────────────────────────────────────────────────────────
VPC_ID=$(get_vpc_id)

# 1차 사전 정리
cleanup_vpc "$VPC_ID"

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo ""
  echo "=== terraform destroy 시도 $attempt / $MAX_RETRIES ==="
  if terraform destroy "$@" 2>&1 | tee /tmp/tf_destroy_output.log; then
    echo "=== destroy 완료 ==="
    rm -f /tmp/tf_destroy_output.log
    exit 0
  fi

  echo "=== destroy 실패 ==="

  if [ $attempt -lt $MAX_RETRIES ]; then
    # 에러 출력에서 VPC ID 자동 추출 (변경되었을 수 있으므로)
    FAILED_VPC=$(grep -oP 'vpc-[0-9a-f]+' /tmp/tf_destroy_output.log 2>/dev/null | head -1)
    CLEANUP_TARGET="${FAILED_VPC:-$VPC_ID}"

    if [ -n "$CLEANUP_TARGET" ]; then
      echo ""
      echo "=== 실패 원인 리소스 재정리 후 재시도 ==="
      cleanup_vpc "$CLEANUP_TARGET"
    fi

    WAIT=$((30 * attempt))
    echo "=== ${WAIT}초 대기 후 재시도 ==="
    sleep "$WAIT"
  fi

  attempt=$((attempt + 1))
done

rm -f /tmp/tf_destroy_output.log
echo "=== destroy ${MAX_RETRIES}회 모두 실패했습니다. ==="
echo "수동 확인: aws ec2 describe-addresses / describe-network-interfaces --filters Name=vpc-id,Values=$VPC_ID"
exit 1
