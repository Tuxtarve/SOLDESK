# 프로젝트 설명

S3 정적 웹호스팅을 기반으로 티켓팅 프론트엔드를 배포하고, EKS(ingress)로 read/write API와 worker를 운영하는 프로젝트입니다.
RDS + ElastiCache(Redis) + SQS(FIFO)까지 포함해, Terraform 한 번으로 인프라부터 K8s bootstrap까지 이어지는 흐름을 포함합니다.

# 시작환경 설명

## 1. `terraform/terraform.tfvars` 작성

- AWS 자격증명은 **기본적으로 `~/.aws/config`, `~/.aws/credentials`(또는 SSO)** 를 사용한다고 가정합니다.
- 아래는 `terraform/terraform.tfvars`를 복사해 **값만 비워둔 템플릿**입니다. 필요한 값만 채워 넣으시면 됩니다.

```hcl
########################################
# 사용자 입력(환경 의존)
########################################

# RDS 비밀번호 (로컬 파일로만 관리; repo에는 커밋되지 않음)
db_password = ""
# ex) db_password = "abc"

# 정적 파일 경로 (terraform/ 기준 상대경로)
# ex) s3_hosting_source_dir = "../frontend/src"
# ex) s3_hosting_source_dir = "../frontend/dist"
s3_hosting_source_dir = "../frontend/src"

# Docker/ECR 배포 설정 (상대방 환경에 맞게 수정)
image_tag = ""
# ex) image_tag = "v1"

# ECR repository path (registry 제외). 예: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<repo>:<tag> 에서 <repo> 부분
ecr_repo_ticketing_was = ""
# ex) ecr_repo_ticketing_was = "myteam/ticketing-was"

# ECR repository path (registry 제외). 워커 서비스 이미지 repo
ecr_repo_worker_svc = ""
# ex) ecr_repo_worker_svc = "myteam/worker-svc"

# Ingress 리소스 이름. bootstrap이 Ingress의 ALB hostname을 읽어 S3의 api-origin.js를 동기화할 때 사용
k8s_ingress_name = ""
# ex) k8s_ingress_name = "my-ingress"

########################################
# 이 밑으로는 고정
########################################

env = "prod"

aws_region = "ap-northeast-2"

eks_cluster_name = "ticketing-eks"

github_repo = "your-org/ticketing"

enable_db_schema_init = true

enable_s3_hosting_v2_module = true

run_k8s_bootstrap_after_apply = true

enable_cloudfront_for_frontend = false

```

## 2. WAS 이미지(ECR) 만들기

### 2.1 ECR 레포 생성(최초 1회)

`terraform/terraform.tfvars`의 아래 값들이 “레포 주소(레포 이름)”입니다. (registry 제외)

- `ecr_repo_ticketing_was`
- `ecr_repo_worker_svc`

예를 들어 `ecr_repo_ticketing_was = "ticketing/ticketing-was"` 라면, ECR에 생성되는 repository name도 그대로 `ticketing/ticketing-was` 입니다.

아래 명령은 **현재 설정된 리전**에 레포 2개를 만들어줍니다(이미 있으면 에러가 날 수 있으니, 그 경우는 무시하고 진행하셔도 됩니다).

```bash
AWS_REGION="<tfvars의 aws_region 값>"

aws ecr create-repository --repository-name "<tfvars의 ecr_repo_ticketing_was 값>" --region "$AWS_REGION"
aws ecr create-repository --repository-name "<tfvars의 ecr_repo_worker_svc 값>" --region "$AWS_REGION"
```

### 2.2 `scripts/img.sh` 설명

`scripts/img.sh`는 아래를 한 번에 수행합니다.

- 현재 AWS 계정에서 `ACCOUNT_ID`를 조회(`aws sts get-caller-identity`)
- ECR 로그인
- `services/ticketing-was`, `services/worker-svc`를 Docker build
- ECR로 push

기본 동작(수정하지 않은 상태) 기준으로, push되는 이미지 주소는 아래 형태입니다.

```text
<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<repo>:<tag>
```

### 2.3 만든 이미지 주소를 1번 어디에 적나?

- **tag**: `terraform/terraform.tfvars`의 `image_tag`
- **repo(레포 주소/이름)**: `terraform/terraform.tfvars`의 `ecr_repo_ticketing_was`, `ecr_repo_worker_svc`

즉, 아래 3개가 “이미지 경로”를 결정합니다.

- `image_tag`
- `ecr_repo_ticketing_was`
- `ecr_repo_worker_svc`

## 3. 어플라이 후 (zzzzz output)

1. `terraform init, apply`를 완료합니다.

2. `terraform apply` 정상 작동후 아웃풋을 확인


```text
.............................

  bash ../scripts/normalize-line-endings.sh

  export DB_USER=root
  export DB_PASSWORD=

  bash ../k8s/scripts/apply-secrets-from-terraform.sh
  kubectl apply -k ../k8s
  bash ../k8s/scripts/sync-s3-endpoints-from-ingress.sh
  kubectl -n ${var.ticketing_namespace} patch cm ${var.ticketing_configmap_name} --type merge -p '{"data":{"DB_NAME":"ticketing"}}'
  kubectl -n ${var.ticketing_namespace} rollout restart deploy/${var.worker_deployment_name}
  kubectl -n ${var.ticketing_namespace} rollout restart deploy/${var.read_api_deployment_name}

  .............................
  EOT
  zzzzzz_url = "출력될 url"
```

3. 출력된 문자를 그대로 CLI에 붙여넣어 실행합니다. (아래는 출력 예시 + 1줄 설명)

```bash
bash ../scripts/normalize-line-endings.sh
# 설명: Windows에서 수정된 스크립트(CRLF)가 있어도 리눅스에서 깨지지 않게 줄바꿈을 정규화합니다.

export DB_USER=root
# 설명: DB 초기화/시크릿 생성에 사용할 DB 유저(기본 root)를 환경변수로 설정합니다.

export DB_PASSWORD="tfvars에 넣었던 패스워드와 동일하게"
# 설명: DB 비밀번호를 환경변수로 설정합니다(터미널 히스토리에 남지 않게 주의).

bash ../k8s/scripts/apply-secrets-from-terraform.sh
# 설명: Terraform output(DB/Redis/SQS)을 읽어 `ticketing-secrets` Secret을 클러스터에 생성/갱신합니다.

kubectl apply -k ../k8s
# 설명: kustomize로 k8s 매니페스트를 한 번에 적용합니다(Deployment/Service/Ingress 등).

bash ../k8s/scripts/sync-s3-endpoints-from-ingress.sh
# 설명: Ingress의 ALB hostname을 읽어 S3의 `api-origin.js`를 현재 ALB 주소로 동기화합니다.

kubectl -n ticketing patch cm ticketing-config --type merge -p '{"data":{"DB_NAME":"ticketing"}}'
# 설명: ConfigMap의 DB_NAME을 보장하고(필요 시) 값이 바뀌면 앱이 새 설정을 읽게 합니다.

kubectl -n ticketing rollout restart deploy/worker-svc
# 설명: worker 파드를 재시작해 최신 Secret/ConfigMap을 반영합니다.

kubectl -n ticketing rollout restart deploy/read-api
# 설명: read-api 파드를 재시작해 최신 Secret/ConfigMap을 반영합니다.
```

4. 최하단 zzzzzz_url에 출력된 url로 접속을 확인 (s3정적 웹호스팅 주소)


# 구조 설명

```text
soldesk-1-HEE/
├── README.md
├── terraform/                 # IaC: VPC/EKS/RDS/ElastiCache/SQS/S3(옵션) + apply 후 k8s bootstrap
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars       # 사용자 환경 값(로컬)
│   ├── k8s_bootstrap.tf       # apply 후 kubectl/시크릿/롤아웃 자동화
│   └── modules/               # network, eks, rds, elasticache, sqs, s3_hosting_v2 등
├── k8s/                       # kustomize 기반 매니페스트 (read-api/write-api/worker/ingress/configmap/sa)
│   ├── kustomization.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   ├── sqs-service-account.yaml
│   ├── read-api/
│   ├── write-api/
│   └── worker-svc/
├── services/                  # 백엔드 서비스 소스 (ticketing-was, worker-svc)
├── frontend/                  # 정적 프론트엔드 소스 (S3에 업로드)
├── db-schema/                 # DB 스키마/시드 SQL
├── scripts/                   # 이미지 빌드/유틸 스크립트
└── config/                    # 프로젝트 설정/리소스(있을 경우)
```

## 핵심 흐름(어디서 무엇을 함)

- **Terraform (인프라 생성)**: `terraform/main.tf`
  - **VPC/서브넷/보안그룹**: `terraform/modules/network/`
  - **EKS + 노드그룹 + IRSA(권한)**: `terraform/modules/eks/`
  - **RDS(MySQL) + Reader/Writer**: `terraform/modules/rds/`
  - **ElastiCache(Redis)**: `terraform/modules/elasticache/`
  - **SQS(FIFO + DLQ)**: `terraform/modules/sqs/`
  - **S3 정적호스팅(+옵션 CloudFront)**: `terraform/modules/s3_hosting/` (v2)

- **Terraform apply 이후 자동 bootstrap**: `terraform/k8s_bootstrap.tf`
  - `run_k8s_bootstrap_after_apply = true`면, apply 마지막에 `terraform/scripts/post_apply_k8s_bootstrap.sh`를 실행해서
    - EKS kubeconfig 갱신
    - Terraform output 기반 Secret 생성/갱신
    - `k8s/` 매니페스트 적용(kustomize)
    - (옵션) Ingress의 ALB 주소를 읽어 S3의 `api-origin.js` 동기화
    - 필요한 Deployment 롤아웃(restart)

- **Kubernetes 매니페스트(클러스터에 올라가는 것)**: `k8s/`
  - **read-api**: `k8s/read-api/deployment.yaml` (컨테이너 `read-api`, 이미지 `ticketing/ticketing-was`)
  - **write-api**: `k8s/write-api/deployment.yaml` (컨테이너 `write-api`, 이미지 `ticketing/ticketing-was`)
  - **worker-svc**: `k8s/worker-svc/deployment.yaml` (컨테이너 `worker-svc`, 이미지 `ticketing/worker-svc`)
  - **Ingress(ALB)**: `k8s/ingress.yaml`
  - **ConfigMap/Secret 연동**: `k8s/configmap.yaml` + `k8s/scripts/apply-secrets-from-terraform.sh`

- **서비스 코드(애플리케이션 로직)**: `services/`
  - **`services/ticketing-was/`**: FastAPI 기반 API (read/write는 실행 커맨드만 다르게 구동)
  - **`services/worker-svc/`**: SQS 메시지 소비(예매 처리) 워커

- **정적 프론트엔드**: `frontend/`
  - `terraform/modules/s3_hosting`가 `s3_hosting_source_dir`을 S3로 업로드해서 정적 호스팅합니다.

- **DB 스키마/시드**: `db-schema/`
  - `enable_db_schema_init = true`면, apply 중 `terraform/scripts/init_db_schema_via_k8s.sh`로 클러스터 내부에서 스키마/시드를 적용합니다.

- **로컬 편의 스크립트(수동 실행/보조)**: `scripts/`
  - **줄바꿈(CRLF) 정규화**: `scripts/normalize-line-endings.sh`
  - **이미지 빌드/푸시**: `scripts/img.sh`
  - **수동 bootstrap(출력 zzzzz 따라가기)**: `scripts/k8s-bootstrap-manual.sh`