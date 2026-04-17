==========================================================
  소서비스(Ticketing) 독립 배포 가이드
==========================================================

[이 가이드가 하는 일]
이 프로젝트를 자기 AWS 계정에 통째로 복제해서, 원본과 똑같은 구조로
독립적으로 운영/실험할 수 있게 만들어줍니다. 원본과 데이터/리소스는
완전히 분리됩니다. 따라만 하면 됩니다.

[결과물]
자기 AWS 계정에 다음이 자동 구축됩니다.
  - 네트워크: VPC / Subnet / NAT / ALB(internal)
  - 컴퓨트: EKS (t3.small 노드)
  - 데이터: RDS MySQL(Writer+Reader) / ElastiCache Redis / SQS(FIFO 2개)
  - 프론트: S3 정적 호스팅 + CloudFront
  - 인증: Cognito User Pool + Hosted UI
  - GitOps: ArgoCD (자기 git repo 감시)
  - 모니터링: Prometheus + Grafana (EKS 내)
  - 애플리케이션: 영화·공연·극장 티켓팅 풀스택

[예상 소요]
  시간: 약 40 ~ 60분 (거의 자동)
  비용: 하루 약 $5 ~ $10 (EKS + RDS + NAT + ALB 기준)

[지원 OS]
Windows(Git Bash), macOS, Linux 모두 가능. 예시는 Git Bash 기준.


==========================================================
 0. 사전 준비물
==========================================================

[A] 계정 준비
  □ AWS 계정 (IAM Administrator 권한 유저)
  □ GitHub 계정
  □ (선택) Slack Webhook URL — 알림 받고 싶으면

[B] 로컬 PC에 설치할 도구
  □ git
  □ AWS CLI v2          https://aws.amazon.com/cli/
  □ Terraform >= 1.5    https://developer.hashicorp.com/terraform/install
  □ Docker Desktop      (없으면 GitHub Actions로 대체 가능 — 스크립트가 안내해줌)
  □ kubectl, helm       → 자동 설치되므로 설치 불필요

[C] AWS CLI 로그인 (최초 1회)
  명령어:
    aws configure
  물어보는 값:
    AWS Access Key ID:     [본인 키]
    AWS Secret Access Key: [본인 시크릿]
    Default region name:   ap-northeast-2
    Default output format: json

  확인:
    aws sts get-caller-identity
  → "Account": "123456789012" 처럼 본인 계정 번호가 찍히면 OK


==========================================================
 1. Git Repo 자기 계정으로 복제
==========================================================

방법 A (추천 — GitHub Fork)
  1) 브라우저에서 https://github.com/sxk34/soldesk 접속
  2) 우상단 "Fork" 버튼 클릭 → 자기 계정으로 fork
  3) 터미널에서 clone:
       git clone https://github.com/<본인GitHub아이디>/soldesk.git
       cd soldesk
       git checkout FINAL

방법 B (새 repo로 push)
  1) 자기 GitHub에서 새 repo 생성 (예: my-ticketing, Public 권장)
  2) 터미널:
       git clone https://github.com/sxk34/soldesk.git
       cd soldesk
       git checkout FINAL
       git remote set-url origin https://github.com/<본인GitHub아이디>/my-ticketing.git
       git push -u origin FINAL

  ※ 이후 이 가이드에서 말하는 "본인 repo" 는 이 fork / 새 repo 를 의미.


==========================================================
 2. 수정할 파일 — 딱 3곳 + GitHub Secrets 2개
==========================================================

──────────────────────────────────────────────────────────
[수정 1] terraform/terraform.tfvars
──────────────────────────────────────────────────────────
현재 내용:
    slack_webhook_url = "https://hooks.slack.com/services/T0ASF3ZN.../..."
    alb_listener_arn = ""
    frontend_callback_domain = ""

이렇게 바꿔주세요:
    # 본인 슬랙 웹훅 (없으면 빈 문자열 "" 로)
    slack_webhook_url = ""

    # Cognito 호스티드 UI 도메인 prefix (★ 전역 유일, 절대 "ticketing-auth-734772" 그대로 두지 말 것)
    # 본인만의 유니크 문자열로 작성. 숫자 포함 권장.
    # 예: "myticket-auth-jd4k29"
    cognito_domain_prefix = "myticket-auth-<본인유니크문자열>"

    # 아래 2줄은 그대로 비워두세요. setup-all.sh 가 자동으로 채워줍니다.
    alb_listener_arn = ""
    frontend_callback_domain = ""

──────────────────────────────────────────────────────────
[수정 2] argocd/application.yaml  (11번째 줄)
──────────────────────────────────────────────────────────
찾을 줄:
    repoURL: https://github.com/sxk34/soldesk.git

이렇게 바꾸기 (본인 repo 주소로):
    repoURL: https://github.com/<본인GitHub아이디>/soldesk.git
            (또는 방법 B 로 만든 repo면 /my-ticketing.git 등)

※ 바로 아래 줄 `targetRevision: FINAL` 은 그대로 두세요 (브랜치명 동일).

※ 수정 후 반드시 본인 repo 로 push 해야 ArgoCD 가 바뀐 값을 봅니다:
    git add argocd/application.yaml terraform/terraform.tfvars
    git commit -m "chore: 본인 환경값으로 교체"
    git push origin FINAL

──────────────────────────────────────────────────────────
[수정 3] GitHub Secrets 등록 (웹 브라우저에서)
──────────────────────────────────────────────────────────
본인 GitHub 의 fork / 새 repo 페이지 에서:
  Settings → Secrets and variables → Actions → "New repository secret"

아래 2개를 등록 (지금 등록할 수 있는 건 1번, 2번은 배포 후 등록):

  ① 이름: AWS_ACCOUNT_ID
     값: 본인 AWS 계정 12자리 숫자
     확인 명령: aws sts get-caller-identity --query Account --output text

  ② 이름: AWS_ROLE_ARN
     값: (★ 지금은 임시값 "placeholder" 넣어두기)
     → 3단계 배포 완료 후 아래 "5단계" 에서 실제 값으로 업데이트할 예정


==========================================================
 3. 환경변수 설정 (터미널에서)
==========================================================

Git Bash 또는 터미널을 열어서 프로젝트 폴더로 이동:
    cd /c/Users/user/OneDrive/Desktop/soldesk      (윈도우 예시)
    cd ~/soldesk                                    (맥/리눅스 예시)

환경변수 설정 (★ 현재 터미널 세션에서만 유효 — 새 창 열면 다시 설정):

    # RDS 마스터 비밀번호 (본인이 정함)
    # 규칙: 8자 이상, 대/소문자 + 숫자 + 특수문자 조합 추천
    export DB_PASSWORD='MyStr0ng!Pass2026'

    # Terraform 이 참조하는 동일한 값
    export TF_VAR_db_password="$DB_PASSWORD"

확인:
    echo $DB_PASSWORD          # 비어있으면 안 됨
    echo $TF_VAR_db_password   # 비어있으면 안 됨


==========================================================
 4. 한 방 배포 실행 (자동)
==========================================================

아래 명령어 한 줄이면 전부 자동으로 돌아갑니다.

    bash scripts/setup-all.sh

스크립트가 자동 수행하는 것 (총 14단계):
    [1]  Terraform 1차 apply       → VPC/EKS/RDS/Cognito/S3/CloudFront 생성
    [2]  kubeconfig 설정
    [3]  AWS Load Balancer Controller 설치
    [4]  Cluster Autoscaler 설치
    [5]  KEDA 설치
    [6]  Prometheus + Grafana 설치
    [7]  Kubernetes Secret 생성
    [8]  RDS 에 DB 스키마 + 시드데이터 주입
    [9]  Docker 이미지 빌드 → ECR push
    [10] ArgoCD 설치 + Application 등록
    [11] ArgoCD Sync 완료 대기
    [12] 프론트엔드 S3 업로드
    [13] Internal ALB ARN 추출 → tfvars 자동 기록 → Terraform 2차 apply
         (★ 1·2차 apply 전부 이 스크립트가 알아서 처리)
    [14] 모니터링 접속 안내 출력

완료 시 마지막 출력:
    프론트엔드:    https://xxxxxx.cloudfront.net
    API (사용자):  https://xxxxxx.cloudfront.net/api/events
    API GW (직접): https://yyyyy.execute-api.ap-northeast-2.amazonaws.com

이 URL 을 메모장에 복사해 두세요.


==========================================================
 5. GitHub Actions 용 IAM Role ARN 등록 (1차 배포 완료 후)
==========================================================

Terraform 이 GitHub Actions OIDC Role 을 자동으로 만들어 놓습니다.
그 ARN 을 GitHub Secrets 에 넣어야 앞으로 코드 push 시 CI 가 동작합니다.

    cd terraform
    terraform output -list                          # 사용 가능한 output 이름 확인
    terraform output github_actions_role_arn        # 또는 비슷한 이름

예시 출력:
    "arn:aws:iam::123456789012:role/ticketing-github-actions"

이 값을 복사 → GitHub repo → Settings → Secrets → Actions 에서
AWS_ROLE_ARN 시크릿 값을 "placeholder" → 위 ARN 으로 업데이트.

이제부터 본인 repo 의 FINAL 브랜치에 코드 push 하면 GitHub Actions 가
자동으로 이미지 빌드 → ECR push → k8s 매니페스트 업데이트 → ArgoCD 배포 합니다.

※ CI/CD 가 필요 없고 그냥 현재 배포만 쓸 거면 이 단계는 건너뛰어도 됩니다.


==========================================================
 6. 동작 확인
==========================================================

[A] 프론트엔드 접속
  터미널 마지막에 나온 CloudFront URL 접속
  → 로그인 화면이 뜨면 성공
  → 회원가입 (Cognito) → 로그인 → 영화 목록 → 예매 테스트

[B] ArgoCD UI (K8s 동기화 상태)
  kubectl port-forward -n argocd svc/argocd-server 8080:80
  브라우저: http://localhost:8080
  로그인: admin / (비번은 아래 명령어)
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" | base64 -d

[C] Grafana (모니터링)
  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
  브라우저: http://localhost:3000
  로그인: admin / prom-operator

[D] 파드 상태 확인
  kubectl get pods -n ticketing
  → Running / 1/1 로 뜨면 정상


==========================================================
 7. 자주 나는 문제 (트러블슈팅)
==========================================================

[Q1] Cognito domain 이 already exists 에러
  원인: terraform.tfvars 의 cognito_domain_prefix 가 전역 유일하지 않음.
  조치: 더 무작위한 값으로 바꿔서 다시:
        cognito_domain_prefix = "myticket-auth-xj293kdz"

[Q2] "variable 'db_password' is not set" 에러
  원인: TF_VAR_db_password 환경변수 누락.
  조치: export TF_VAR_db_password='비밀번호' 한 뒤 재실행.

[Q3] setup-all.sh 중간에 실패
  조치: 그대로 다시 실행하면 대부분 이어서 진행됨 (멱등):
        bash scripts/setup-all.sh
  그래도 안 되면 전부 밀고 재시도:
        bash scripts/destroy.sh
        bash scripts/setup-all.sh

[Q4] ArgoCD Application 이 OutOfSync 또는 Unknown 상태
  원인: argocd/application.yaml 의 repoURL 이 본인 repo 를 안 가리킴.
       (또는 수정 후 본인 repo 로 push 안 함)
  조치: 2단계 [수정 2] 다시 확인 → git push origin FINAL.
        ArgoCD UI 에서 Refresh 버튼.

[Q5] Pod 가 ImagePullBackOff
  원인: Docker 미설치 상태로 setup-all.sh 돌려서 ECR 에 이미지가 없음.
  조치: (A) 본인 repo 에 아무 커밋이나 push → GitHub Actions 가 빌드/푸시
       (B) Docker Desktop 설치 후 수동 빌드:
           cd soldesk
           ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
           REGION=ap-northeast-2
           ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
           aws ecr get-login-password --region $REGION | \
             docker login --username AWS --password-stdin $ECR
           docker build -t $ECR/ticketing/ticketing-was:latest services/ticketing-was
           docker push $ECR/ticketing/ticketing-was:latest
           docker build -t $ECR/ticketing/worker-svc:latest services/worker-svc
           docker push $ECR/ticketing/worker-svc:latest
           docker build -t $ECR/ticketing/frontend:latest frontend
           docker push $ECR/ticketing/frontend:latest
           kubectl rollout restart deployment -n ticketing

[Q6] CloudFront 접속 시 403
  원인: 첫 배포 후 전파 지연 (3~15분).
  조치: 10분 정도 기다렸다 재시도. 그래도 안 되면:
        aws cloudfront create-invalidation \
          --distribution-id <배포ID> --paths "/*"

[Q7] kubectl 명령이 "No cluster found"
  조치: aws eks update-kubeconfig --name ticketing-eks --region ap-northeast-2


==========================================================
 8. 다 쓰고 나서 — 전체 삭제 (과금 멈춤)
==========================================================

★ 중요: destroy 직전에 PVC 먼저 삭제 (고아 EBS 방지)
──────────────────────────────────────────────────────────
scripts/destroy.sh 는 VPC · ENI · ALB · SG 는 정리하지만,
Prometheus / Grafana 가 동적으로 만든 EBS 볼륨은 자동 정리하지 않습니다.
(EKS 가 먼저 사라지면 EBS CSI Controller 도 같이 죽어서 EBS 삭제 API 가
호출되지 않음 → EBS 가 "available" 상태로 남아 계속 과금됩니다)

따라서 destroy 전에 아래 명령으로 PVC 를 먼저 지워야 EBS 가 깨끗이
사라집니다. CSI 가 살아있을 때 삭제해야 reclaimPolicy: Delete 가 동작함.

    kubectl delete pvc --all -n monitoring --wait=false
    kubectl delete pvc --all -n ticketing  --wait=false
    sleep 30         # CSI 가 EBS 삭제 API 다 호출할 시간 확보

그 다음 destroy:

    bash scripts/destroy.sh

  이 스크립트는:
    - VPC 내 EIP / ALB / NLB / TG / ENI / SG 사전 정리
    - Terraform destroy (VPC/EKS/RDS/ElastiCache/SQS/S3/Cognito/...)
    - 실패 시 최대 4회 재시도

★ destroy 후 고아 EBS 확인 (권장)
──────────────────────────────────────────────────────────
위 PVC 사전 삭제를 건너뛰었거나 중간에 실패했으면, AWS 계정에
"available" 상태 EBS 볼륨이 고아로 남아서 계속 과금됩니다.

조회:
    aws ec2 describe-volumes --region ap-northeast-2 \
      --filters "Name=status,Values=available" \
      --query 'Volumes[*].[VolumeId,Size,CreateTime,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]' \
      --output table

출력 예시:
    vol-0abc...   20   2026-04-17T...   prometheus-kube-prometheus-stack-...
    vol-0def...   10   2026-04-17T...   grafana-...

삭제:
    aws ec2 delete-volume --volume-id vol-0abc... --region ap-northeast-2

주의: destroy 후에도 CloudWatch Logs, ECR 이미지, 고아 EBS 등이 남아서
      과금될 수 있으니 AWS 콘솔 Billing 대시보드에서 며칠 후 0원인지
      꼭 확인하세요.


==========================================================
 최종 체크리스트
==========================================================
□ Git repo fork 또는 새 repo 로 push, FINAL 브랜치 사용
□ terraform/terraform.tfvars 의 cognito_domain_prefix 본인값으로 변경
□ terraform/terraform.tfvars 의 slack_webhook_url 본인값 또는 "" 로 변경
□ argocd/application.yaml 의 repoURL 본인 repo 로 변경
□ 위 수정사항을 본인 repo 의 FINAL 브랜치로 push
□ GitHub Secrets 에 AWS_ACCOUNT_ID 등록
□ (선택) GitHub Secrets 에 AWS_ROLE_ARN 등록 (배포 후에도 OK)
□ 터미널에서 DB_PASSWORD + TF_VAR_db_password export
□ aws sts get-caller-identity 로 본인 계정 확인
□ bash scripts/setup-all.sh 실행
□ 완료 후 CloudFront URL 접속해서 동작 확인

==========================================================
 문의
==========================================================
원본 repo: https://github.com/sxk34/soldesk  (FINAL 브랜치)
문제 생기면 원본 repo 에 Issue 남기거나 관리자(sxk34) 에게 문의.
