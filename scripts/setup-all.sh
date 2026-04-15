#!/usr/bin/env bash
# terraform apply 후 EKS 클러스터 전체 셋업을 자동으로 수행합니다.
# 사용법: bash scripts/setup-all.sh
# DB_PASSWORD 환경변수가 필요합니다: export DB_PASSWORD='your-password'
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

# ── 0. DB_PASSWORD 확인 ──
if [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "ERROR: DB_PASSWORD 환경변수를 먼저 설정하세요." >&2
  echo "  export DB_PASSWORD='your-password'" >&2
  exit 1
fi

# ── 0.1. helm 자동 설치 (install-* 스크립트 3종이 전부 helm 필요) ──
# Git Bash(MINGW) / Linux / macOS 모두 지원. $HOME/bin에 배치 + PATH 주입.
# 다음 세션부터 PATH 유지되도록 ~/.bashrc에 1회 등록.
ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  # 이전 실행에서 $HOME/bin에 깔았는데 PATH만 빠진 경우
  if [[ -x "$HOME/bin/helm" || -x "$HOME/bin/helm.exe" ]]; then
    export PATH="$HOME/bin:$PATH"
    command -v helm >/dev/null 2>&1 && { echo "helm 기존 설치 발견 (PATH 갱신)"; return 0; }
  fi

  echo "helm 미설치 → 자동 설치 시작"
  local HELM_VERSION="v3.16.3"
  local TMP_DIR
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$HOME/bin"

  local UNAME
  UNAME="$(uname -s 2>/dev/null || echo unknown)"
  case "$UNAME" in
    MINGW*|MSYS*|CYGWIN*)
      local ZIP_NAME="helm-${HELM_VERSION}-windows-amd64.zip"
      curl -fsSL "https://get.helm.sh/${ZIP_NAME}" -o "$TMP_DIR/helm.zip" \
        || { echo "ERROR: helm 다운로드 실패"; rm -rf "$TMP_DIR"; return 1; }
      # Windows에서 가장 확실한 unzip은 PowerShell Expand-Archive
      local ZIP_WIN OUT_WIN
      ZIP_WIN="$(cygpath -w "$TMP_DIR/helm.zip" 2>/dev/null || echo "$TMP_DIR/helm.zip")"
      OUT_WIN="$(cygpath -w "$TMP_DIR" 2>/dev/null || echo "$TMP_DIR")"
      powershell -NoProfile -Command \
        "Expand-Archive -Path '$ZIP_WIN' -DestinationPath '$OUT_WIN' -Force" \
        || { echo "ERROR: helm 압축 해제 실패"; rm -rf "$TMP_DIR"; return 1; }
      cp "$TMP_DIR/windows-amd64/helm.exe" "$HOME/bin/helm.exe"
      ;;
    Linux)
      local TAR_NAME="helm-${HELM_VERSION}-linux-amd64.tar.gz"
      curl -fsSL "https://get.helm.sh/${TAR_NAME}" -o "$TMP_DIR/helm.tgz" \
        || { echo "ERROR: helm 다운로드 실패"; rm -rf "$TMP_DIR"; return 1; }
      tar xzf "$TMP_DIR/helm.tgz" -C "$TMP_DIR"
      cp "$TMP_DIR/linux-amd64/helm" "$HOME/bin/helm"
      chmod +x "$HOME/bin/helm"
      ;;
    Darwin)
      local TAR_NAME="helm-${HELM_VERSION}-darwin-amd64.tar.gz"
      curl -fsSL "https://get.helm.sh/${TAR_NAME}" -o "$TMP_DIR/helm.tgz" \
        || { echo "ERROR: helm 다운로드 실패"; rm -rf "$TMP_DIR"; return 1; }
      tar xzf "$TMP_DIR/helm.tgz" -C "$TMP_DIR"
      cp "$TMP_DIR/darwin-amd64/helm" "$HOME/bin/helm"
      chmod +x "$HOME/bin/helm"
      ;;
    *)
      echo "ERROR: 미지원 OS ($UNAME). helm을 직접 설치 후 재시도하세요." >&2
      rm -rf "$TMP_DIR"
      return 1
      ;;
  esac

  rm -rf "$TMP_DIR"
  export PATH="$HOME/bin:$PATH"

  if ! command -v helm >/dev/null 2>&1; then
    echo "ERROR: helm 자동 설치 실패" >&2
    return 1
  fi

  echo "helm 설치 완료: $(helm version --short 2>/dev/null || echo unknown) → $HOME/bin"

  # ~/.bashrc에 PATH 영구 등록 (중복 방지)
  if [[ -f "$HOME/.bashrc" ]] && ! grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
    echo "  → ~/.bashrc에 PATH 영구 등록"
  fi
}

ensure_helm

# ── 0.2. kubectl 자동 설치 (EKS 1.30 호환 kubectl v1.30.0) ──
# helm은 내부 k8s 클라이언트를 써서 kubectl 없이도 돌지만,
# apply-ticketing-k8s.sh · DB 스키마 초기화 · rollout · ingress 조회 등에서 kubectl 필수.
ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x "$HOME/bin/kubectl" || -x "$HOME/bin/kubectl.exe" ]]; then
    export PATH="$HOME/bin:$PATH"
    command -v kubectl >/dev/null 2>&1 && { echo "kubectl 기존 설치 발견 (PATH 갱신)"; return 0; }
  fi

  echo "kubectl 미설치 → 자동 설치 시작"
  mkdir -p "$HOME/bin"
  local KUBECTL_VERSION="v1.30.0"
  local UNAME
  UNAME="$(uname -s 2>/dev/null || echo unknown)"

  case "$UNAME" in
    MINGW*|MSYS*|CYGWIN*)
      curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/windows/amd64/kubectl.exe" \
        -o "$HOME/bin/kubectl.exe" \
        || { echo "ERROR: kubectl 다운로드 실패"; return 1; }
      ;;
    Linux)
      curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o "$HOME/bin/kubectl" \
        || { echo "ERROR: kubectl 다운로드 실패"; return 1; }
      chmod +x "$HOME/bin/kubectl"
      ;;
    Darwin)
      curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/amd64/kubectl" \
        -o "$HOME/bin/kubectl" \
        || { echo "ERROR: kubectl 다운로드 실패"; return 1; }
      chmod +x "$HOME/bin/kubectl"
      ;;
    *)
      echo "ERROR: 미지원 OS ($UNAME). kubectl 수동 설치 후 재시도." >&2
      return 1
      ;;
  esac

  export PATH="$HOME/bin:$PATH"
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl 자동 설치 실패" >&2
    return 1
  fi
  echo "kubectl 설치 완료 → $HOME/bin"
}

ensure_kubectl

# ── 0.5. 영구 EBS 볼륨 import (이전 destroy/apply 사이클에서 살아남은 볼륨 재사용) ──
echo "=========================================="
echo " [0.5] 모니터링 영구 EBS 볼륨 확인"
echo "=========================================="
REGION_FOR_IMPORT="$(terraform output -raw aws_region 2>/dev/null || echo "ap-northeast-2")"
EBS_ID=$(aws ec2 describe-volumes \
  --region "$REGION_FOR_IMPORT" \
  --filters "Name=tag:Name,Values=ticketing-monitoring-data" "Name=tag:Persistent,Values=true" \
  --query "Volumes[?State=='available' || State=='in-use'] | [0].VolumeId" \
  --output text 2>/dev/null || echo "None")

if [ -n "$EBS_ID" ] && [ "$EBS_ID" != "None" ]; then
  if ! terraform state list 2>/dev/null | grep -q 'module.monitoring.aws_ebs_volume.monitoring_data'; then
    echo "기존 EBS 볼륨 발견: $EBS_ID — terraform state에 import 합니다 (데이터 보존)"
    terraform import 'module.monitoring.aws_ebs_volume.monitoring_data' "$EBS_ID"
  else
    echo "EBS 볼륨이 이미 state에 등록되어 있습니다: $EBS_ID"
  fi
else
  echo "기존 EBS 볼륨 없음 — 새로 생성됩니다 (첫 적용)"
fi

# ── 0.6. tfvars의 옛 alb_listener_arn validity 검증 ──
# destroy.sh를 거치지 않고 setup-all.sh 단독 실행 또는 destroy 실패 후
# 재시도 시, tfvars에 옛 ALB ARN이 박혀 있으면 main.tf의 data
# "aws_lb_listener" 가 NotFound로 첫 apply 자체를 fail시킨다.
TFVARS="$TF_DIR/terraform.tfvars"
if [ -f "$TFVARS" ] && grep -q '^alb_listener_arn' "$TFVARS"; then
  CURRENT_ARN=$(grep '^alb_listener_arn' "$TFVARS" | sed 's/.*= *"//;s/".*//')
  if [ -n "$CURRENT_ARN" ]; then
    if ! aws elbv2 describe-listeners --listener-arns "$CURRENT_ARN" \
        --region "$REGION_FOR_IMPORT" >/dev/null 2>&1; then
      echo "tfvars: 옛 alb_listener_arn이 invalid → 빈값으로 reset"
      sed -i 's|^alb_listener_arn.*|alb_listener_arn = ""|' "$TFVARS"
      sed -i 's|^frontend_callback_domain.*|frontend_callback_domain = ""|' "$TFVARS"
    fi
  fi
fi

# ── 1. Terraform Apply ──
echo "=========================================="
echo " [1/13] Terraform Apply"
echo "=========================================="
terraform apply -auto-approve

# ── 2. kubeconfig 설정 ──
echo ""
echo "=========================================="
echo " [2/13] kubeconfig 설정"
echo "=========================================="
CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
REGION="$(terraform output -raw aws_region)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
echo "kubeconfig 설정 완료"

# ── 3. AWS Load Balancer Controller 설치 ──
echo ""
echo "=========================================="
echo " [3/13] AWS Load Balancer Controller 설치"
echo "=========================================="
bash "$SCRIPTS/install-aws-load-balancer-controller.sh"

# ── 4. Cluster Autoscaler 설치 ──
echo ""
echo "=========================================="
echo " [4/13] Cluster Autoscaler 설치"
echo "=========================================="
bash "$SCRIPTS/install-cluster-autoscaler.sh"

# ── 4.5. KEDA 설치 (SQS 큐 길이 기반 worker-svc 자동 스케일링) ──
echo ""
echo "=========================================="
echo " [5/13] KEDA 설치"
echo "=========================================="
bash "$SCRIPTS/install-keda.sh"

# ── 6. GitOps bootstrap: namespace + Secret ──
# ArgoCD가 k8s/ 매니페스트를 sync 하기 전에 필요한 최소한의 리소스.
# 나머지(Deployment/Service/HPA/Ingress/ScaledObject...)는 ArgoCD가 생성.
echo ""
echo "=========================================="
echo " [6/13] GitOps bootstrap (namespace + secret)"
echo "=========================================="
bash "$SCRIPTS/bootstrap-ticketing-secret.sh"

# ── 7. DB 스키마 초기화 ──
echo ""
echo "=========================================="
echo " [7/13] DB 스키마 초기화"
echo "=========================================="
DB_WRITER_HOST="$(terraform output -raw rds_writer_endpoint)"

kubectl run mysql-init --image=mysql:8.0 --restart=Never -n ticketing \
  --command -- sleep 3600 2>/dev/null || true
echo "MySQL 클라이언트 파드 대기 중..."
kubectl wait --for=condition=Ready pod/mysql-init -n ticketing --timeout=120s

cat "$ROOT/db/schema.sql" | kubectl exec -i mysql-init -n ticketing -- \
  mysql --force --default-character-set=utf8mb4 -h "$DB_WRITER_HOST" -u root -p"$DB_PASSWORD" 2>&1 || true

cat "$ROOT/db/seed.sql" | kubectl exec -i mysql-init -n ticketing -- \
  mysql --default-character-set=utf8mb4 -h "$DB_WRITER_HOST" -u root -p"$DB_PASSWORD" 2>&1 || true

kubectl delete pod mysql-init -n ticketing --wait=false
echo "DB 스키마 + 시드 데이터 적용 완료"

# ── 8. Docker 이미지 빌드 & ECR Push ──
# GitOps 순서: ArgoCD가 Deployment를 만들기 전에 이미지가 ECR에 올라가 있어야
# 첫 pull이 성공한다. 이미지가 없어도 ArgoCD는 Deployment를 만들고 파드는
# ImagePullBackOff로 기다리다가 이미지가 올라오면 자동 복구되긴 하지만,
# Synced+Healthy 상태를 일찍 달성하기 위해 ArgoCD 설치 직전에 push 한다.
#
# kubectl rollout restart는 더 이상 하지 않는다:
#   - 이 시점에는 Deployment가 아직 없다 (ArgoCD가 step 9에서 만듦)
#   - ArgoCD 설치 이후엔 수동 rollout restart가 드리프트로 잡힐 수 있고,
#     이미지 갱신은 git의 kustomization image tag commit으로 처리해야 깔끔하다.
echo ""
echo "=========================================="
echo " [8/13] Docker 이미지 빌드 & ECR Push"
echo "=========================================="
ACCOUNT_ID="$(terraform output -raw aws_account_id)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

if ! command -v docker >/dev/null 2>&1; then
  echo "WARNING: docker CLI 미설치 — 이미지 빌드 skip."
  echo "  ArgoCD가 Deployment를 만들면 ImagePullBackOff 상태로 대기함."
  echo "  나중에 GitHub Actions (build-and-publish.yml) 또는 CloudShell에서 push:"
  echo "    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REGISTRY"
  echo "    for SVC in event-svc reserv-svc worker-svc; do"
  echo "      docker build -t $ECR_REGISTRY/ticketing/\$SVC:latest services/\$SVC"
  echo "      docker push $ECR_REGISTRY/ticketing/\$SVC:latest"
  echo "    done"
else
  aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"
  for SVC in event-svc reserv-svc worker-svc; do
    echo "빌드 & 푸시: $SVC"
    docker build -t "${ECR_REGISTRY}/ticketing/${SVC}:latest" "$ROOT/services/${SVC}"
    docker push "${ECR_REGISTRY}/ticketing/${SVC}:latest"
  done
  echo "이미지 push 완료 (이 시점엔 아직 Deployment 없음 — ArgoCD가 step 9에서 생성)"
fi

# ── 9. ArgoCD 설치 + ticketing Application 등록 ──
echo ""
echo "=========================================="
echo " [9/13] ArgoCD 설치 + Application 등록"
echo "=========================================="
bash "$SCRIPTS/install-argocd.sh"

# ── 10. ArgoCD Application Synced + Healthy 대기 ──
# ArgoCD가 git을 폴링하여 k8s/ 전체를 cluster에 적용. Deployment가 생성되면
# pod가 위에서 push한 이미지를 pull하고 Ready 상태가 되어야 Healthy 판정.
# 첫 sync는 보통 1~3분 내 완료. Ingress가 ALB를 provision하는 데 추가 1~2분.
echo ""
echo "=========================================="
echo " [10/13] ArgoCD Application Synced 대기"
echo "=========================================="
echo "ticketing Application 상태 폴링 (최대 10분)..."
for i in $(seq 1 60); do
  SYNC=$(kubectl get application ticketing -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  HEALTH=$(kubectl get application ticketing -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    echo "  Synced+Healthy 달성 ($((i*10))s)"
    break
  fi
  echo "  [$((i*10))s] sync=$SYNC health=$HEALTH"
  if [[ "$i" -eq 60 ]]; then
    echo "WARNING: 10분 내 Synced+Healthy 안 됨. ArgoCD UI에서 확인 필요." >&2
    kubectl get application ticketing -n argocd -o jsonpath='{.status.conditions}' >&2 || true
    echo "" >&2
  fi
  sleep 10
done
kubectl get pods -n ticketing

# ── 11. 프론트엔드 S3 배포 ──
echo ""
echo "=========================================="
echo " [11/13] 프론트엔드 S3 배포"
echo "=========================================="
BUCKET="ticketing-frontend-${ACCOUNT_ID}"
COGNITO_CLIENT_ID="$(terraform output -raw cognito_client_id)"

# 플레이스홀더를 실제 값으로 치환하여 임시 파일 생성 후 업로드
sed "s|__COGNITO_CLIENT_ID__|${COGNITO_CLIENT_ID}|g" \
  "$ROOT/frontend/src/index.html" > /tmp/index.html

aws s3 cp /tmp/index.html "s3://${BUCKET}/index.html" \
  --content-type "text/html; charset=utf-8" --region "$REGION"
rm -f /tmp/index.html

CF_DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?Id=='S3-frontend']].Id | [0]" \
  --output text 2>/dev/null || true)"
if [[ -n "$CF_DIST_ID" && "$CF_DIST_ID" != "None" ]]; then
  aws cloudfront create-invalidation --distribution-id "$CF_DIST_ID" --paths "/*" >/dev/null
  echo "CloudFront 캐시 무효화 완료"
fi

CLOUDFRONT_DOMAIN="$(terraform output -raw cloudfront_domain)"

# ── 9. API Gateway VPC Link Integration 설정 ──
# Internal ALB가 ingress로 만들어진 후, listener ARN을 추출하여
# tfvars에 박고 terraform apply 재실행 → API GW Integration/Route 생성
# 흐름: 브라우저 → CloudFront → API GW → VPC Link → Internal ALB → EKS
echo ""
echo "=========================================="
echo " [12/13] API Gateway VPC Link Integration 연결"
echo "=========================================="
echo "Internal ALB 주소 대기 중 (ingress가 ALB 만들 때까지)..."
for i in $(seq 1 30); do
  ALB_ADDRESS="$(kubectl get ingress -n ticketing -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$ALB_ADDRESS" ]]; then break; fi
  echo "  대기 중... ($i/30)"
  sleep 10
done

if [[ -z "$ALB_ADDRESS" ]]; then
  echo "WARNING: Internal ALB 주소를 가져올 수 없습니다. API GW Integration이 생성되지 않습니다."
else
  echo "Internal ALB: $ALB_ADDRESS"

  # ALB의 HTTP listener ARN 추출 (API GW VPC Link Integration의 target)
  echo "ALB listener ARN 조회 중..."
  ALB_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?DNSName=='${ALB_ADDRESS}'].LoadBalancerArn | [0]" \
    --output text 2>/dev/null || true)"

  if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
    echo "WARNING: ALB ARN을 찾을 수 없습니다. ALB가 아직 등록 중일 수 있습니다."
  else
    LISTENER_ARN="$(aws elbv2 describe-listeners --region "$REGION" \
      --load-balancer-arn "$ALB_ARN" \
      --query "Listeners[?Port==\`80\`].ListenerArn | [0]" \
      --output text 2>/dev/null || true)"

    if [[ -z "$LISTENER_ARN" || "$LISTENER_ARN" == "None" ]]; then
      echo "WARNING: ALB listener ARN을 찾을 수 없습니다."
    else
      echo "Listener ARN: $LISTENER_ARN"

      # terraform.tfvars에 alb_listener_arn + frontend_callback_domain 저장
      # → 다음 apply에서 API GW Integration/Route 생성 + Cognito 콜백 URL 실제 도메인으로 갱신
      TFVARS="$TF_DIR/terraform.tfvars"
      if [[ -f "$TFVARS" ]] && grep -q '^alb_listener_arn' "$TFVARS"; then
        sed -i "s|^alb_listener_arn.*|alb_listener_arn = \"$LISTENER_ARN\"|" "$TFVARS"
      else
        echo "alb_listener_arn = \"$LISTENER_ARN\"" >> "$TFVARS"
      fi
      if [[ -f "$TFVARS" ]] && grep -q '^frontend_callback_domain' "$TFVARS"; then
        sed -i "s|^frontend_callback_domain.*|frontend_callback_domain = \"$CLOUDFRONT_DOMAIN\"|" "$TFVARS"
      else
        echo "frontend_callback_domain = \"$CLOUDFRONT_DOMAIN\"" >> "$TFVARS"
      fi
      echo "terraform.tfvars에 alb_listener_arn + frontend_callback_domain 저장 완료"

      # Terraform 재실행 → API GW Integration + Route 생성, Cognito 콜백 URL 갱신
      echo "Terraform apply 재실행 중 (API GW Integration 생성 + Cognito 콜백 갱신)..."
      terraform -chdir="$TF_DIR" apply -auto-approve
      echo "API GW Integration 생성 완료. CloudFront 전파 3~5분 소요"
    fi
  fi

  # ── 10. Grafana 대시보드 HTTP API 프로비저닝 ─────────────────
  # Prometheus scrape 설정은 userdata.sh의 ${alb_dns} 템플릿 변수로 이미
  # 처리됨 (monitoring 모듈에 user_data_replace_on_change=true). 두 번째
  # terraform apply에서 alb_listener_arn이 tfvars에 박히는 순간 user_data가
  # 바뀌고 인스턴스가 자동 재생성되어 올바른 scrape_configs로 부팅한다.
  # 따라서 별도의 SSM push는 불필요.
  #
  # Grafana 대시보드 JSON은 Grafana HTTP API로 직접 POST한다. 이 경로는
  # SSM에 의존하지 않고, Web_SG가 3000 포트를 0.0.0.0/0로 열어둔 것을
  # 활용한다. SSM이 불안정한 AMI 조합에서도 동작한다.
  echo ""
  echo "=========================================="
  echo " [13/13] Grafana 대시보드 HTTP API 프로비저닝"
  echo "=========================================="
  MONITORING_IP="$(terraform output -raw monitoring_ec2_ip 2>/dev/null || true)"
  DASH_FILE="$ROOT/monitoring/grafana/dashboards/ticketing-overview.json"
  if [[ -z "$MONITORING_IP" || ! -f "$DASH_FILE" ]]; then
    echo "WARNING: monitoring_ec2_ip 또는 대시보드 파일 누락 — 건너뜀" >&2
  else
    # Grafana가 HTTP 응답할 때까지 대기 (docker-compose up 직후에는 부팅 중)
    echo "Grafana HTTP 응답 대기 중 (http://$MONITORING_IP:3000)..."
    for i in $(seq 1 30); do
      if curl -fsS -o /dev/null "http://$MONITORING_IP:3000/api/health" 2>/dev/null; then
        echo "  Grafana Ready ($((i*5))s)"
        break
      fi
      [[ "$i" -eq 30 ]] && { echo "WARNING: Grafana 2.5분 내 응답 없음 — 건너뜀" >&2; MONITORING_IP=""; break; }
      sleep 5
    done

    if [[ -n "$MONITORING_IP" ]]; then
      # userdata.sh의 GF_SECURITY_ADMIN_USER/PASSWORD 와 동기
      GF_USER="root"
      GF_PASS="soldesk1."

      # 대시보드 업로드 페이로드: { dashboard: <JSON>, overwrite: true, folderId: 0 }
      # jq 의존 없이 printf로 JSON 조립 (Git Bash에 jq 없는 경우 대응)
      PAYLOAD=$(mktemp)
      trap 'rm -f "$PAYLOAD"' EXIT
      DASH_CONTENT=$(cat "$DASH_FILE")
      printf '{"dashboard": %s, "overwrite": true, "folderId": 0, "message": "setup-all.sh"}' \
        "$DASH_CONTENT" > "$PAYLOAD"

      HTTP_CODE=$(curl -s -o /tmp/gf_resp.json -w "%{http_code}" \
        -u "$GF_USER:$GF_PASS" -H "Content-Type: application/json" \
        -X POST "http://$MONITORING_IP:3000/api/dashboards/db" \
        --data-binary "@$PAYLOAD")
      if [[ "$HTTP_CODE" == "200" ]]; then
        echo "Grafana 대시보드 업로드 완료 (HTTP 200)"
      else
        echo "WARNING: Grafana 업로드 실패 (HTTP $HTTP_CODE)" >&2
        cat /tmp/gf_resp.json >&2 || true
      fi
      rm -f /tmp/gf_resp.json
    fi
  fi
fi

echo ""
echo "=========================================="
echo " 전체 셋업 완료!"
echo "=========================================="
API_GW_ENDPOINT="$(terraform output -raw api_gateway_endpoint 2>/dev/null || echo '(아직 미생성)')"
echo "  프론트엔드:    https://${CLOUDFRONT_DOMAIN}"
echo "  API (사용자):  https://${CLOUDFRONT_DOMAIN}/api/events"
echo "  API GW (직접): ${API_GW_ENDPOINT}/api/events"
echo "  Internal ALB:  ${ALB_ADDRESS} (VPC 내부에서만 접근 가능)"
echo "  kubectl get nodes"
echo "  kubectl get pods -n ticketing"
