# 프로젝트 설명

S3 정적 웹호스팅을 기반으로 티켓팅 프론트엔드를 배포하고, EKS(ingress)로 read/write API와 worker를 운영하는 프로젝트입니다.
RDS + ElastiCache(Redis) + SQS(FIFO)까지 포함해, Terraform 한 번으로 인프라부터 K8s bootstrap까지 이어지는 흐름을 포함합니다.

# 시작환경 설명

## Terraform apply 를 실행하는 머신

`terraform apply`가 **`local-exec`로 셸 스크립트**를 돌립니다. 아래 CLI가 **PATH**에 있어야 합니다.

| 도구 | 용도 |
|------|------|
| **Terraform** | (당연) |
| **AWS CLI** (`aws`) | EKS kubeconfig, RDS 등 |
| **kubectl** | DB 스키마 init(`enable_db_schema_init`), `post_apply_k8s_bootstrap` 등 |
| **Helm** (`helm`) | AWS Load Balancer Controller 설치(`alb-controller-helm.tf`) |
| **bash** | 스크립트 인터프리터 |
| **mysql** (클라이언트만) | RDS에 SQL을 자동으로 넣는 흐름과 맞춰 두기(아래 참고) |

설치 참고: [kubectl](https://kubernetes.io/docs/tasks/tools/), [Helm](https://helm.sh/docs/intro/install/).

Rocky/CentOS 등에서 패키지로 없으면 공식 바이너리/스크립트로 설치하는 편이 빠릅니다.

### RDS SQL 자동 적용과 `mysql` 클라이언트

`enable_db_schema_init = true`이면 Terraform이 `db-schema/create.sql`·`db-schema/Insert.sql`을 RDS writer 엔드포인트에 자동으로 실행합니다. **기본 구현**(`terraform/scripts/init_db_schema_via_k8s.sh`)은 EKS 안에 잠깐 띄운 **`mysql:8` 컨테이너**에서 `mysql` CLI로 접속하므로, `terraform apply`를 돌리는 머신에 로컬 `mysql`이 **반드시 있어야 하는 것은 아닙니다**(이미 위 표의 `kubectl`·`aws`로 클러스터 접근이 되면 됨).

다만 같은 SQL을 **로컬에서 직접** 돌리거나(`terraform/scripts/init_db_schema.sh`), 장애 시 수동으로 재적용·검증할 때는 **`mysql` 명령이 PATH에 있는 MariaDB/MySQL 클라이언트**가 있으면 편합니다. RDS 엔진이 MySQL 8 계열이므로, 로컬 클라이언트도 **MySQL 8.x 클라이언트** 또는 이와 호환되는 **MariaDB 클라이언트**를 쓰는 것이 안전합니다.

**Red Hat 계열(RHEL, Rocky Linux 등) 예시**

- 패키지로 쓸 때(둘 중 하나): `dnf install -y mariadb`(MariaDB 클라이언트, `mysql` 명령 제공) 또는 Oracle MySQL 공식 저장소의 `mysql-community-client` 등.
- 설치 확인 예:

```text
mysql --version
mysql  Ver 8.0.45 for Linux on x86_64 (Source distribution)
```

위처럼 **클라이언트 버전**이 나오면 됩니다(서버 데몬 `mysqld`는 로컬에 필요 없음).

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

# Ingress 리소스 이름. bootstrap이 Ingress의 ALB hostname을 읽어 S3의 api-origin.js를 동기화할 때 사용
k8s_ingress_name = ""
# ex) k8s_ingress_name = "my-ingress"


# ECR: 아래 2절 참고. 여기 적은 레포 이름이 2.1·img.sh·Terraform/K8s까지 동일 기준으로 쓰임.

# ECR repository path (registry 제외). 예: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<repo>:<tag> 에서 <repo> 부분
ecr_repo_ticketing_was = ""
# ex) ecr_repo_ticketing_was = "myteam/ticketing-was"

# ECR repository path (registry 제외). 워커 서비스 이미지 repo
ecr_repo_worker_svc = ""
# ex) ecr_repo_worker_svc = "myteam/worker-svc"

# Docker/ECR 배포 설정 (상대방 환경에 맞게 수정)
image_tag = ""
# ex) image_tag = "v1"



########################################
# 이 밑으로는 고정
########################################

s3_hosting_source_dir = "../frontend/src"

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

**전제(1절과 동일):** `terraform/terraform.tfvars`에 이미 `aws_region`, `ecr_repo_ticketing_was`, `ecr_repo_worker_svc`, `image_tag`를 정해 두었다고 가정합니다. 이 절의 ECR·이미지 단계는 그 값을 그대로 따릅니다. AWS 접근은 1절과 같이 `~/.aws/config`(또는 SSO 등)입니다. 2.1의 CLI에서 `--region`을 생략할 때는 **프로필 기본 region을 tfvars의 `aws_region`과 맞춰** 두는 것이 안전합니다.

### 2.1 ECR 레포 생성(최초 1회)

**진행 순서:**  
① 1절 tfvars의 `ecr_repo_ticketing_was`, `ecr_repo_worker_svc` 확인 →  
② 아래 명령의 따옴표 안을 **그 문자열**로 바꿔 `create-repository` 실행 →  
③ `describe-repositories`로 이름 확인

```bash
aws ecr create-repository --repository-name "<ecr_repo_ticketing_was>"
aws ecr create-repository --repository-name "<ecr_repo_worker_svc>"
```

이미 있으면 `RepositoryAlreadyExistsException` — 그대로 다음 단계로.

```bash
aws ecr describe-repositories --query 'repositories[].repositoryName' --output table
```

출력에 보이는 repository name이 위 두 tfvars 값과 같으면 됩니다. (`ecr_repo_worker_svc` → 워커 이미지, `ecr_repo_ticketing_was` → read/write API 이미지.)

### 2.2 `scripts/img.sh` 설명

**용도:** 로컬 `services/ticketing-was`, `services/worker-svc`를 빌드해 ECR로 **push** 합니다. 이후 EKS가 같은 경로의 이미지를 pull 합니다. 코드 수정 후 배포할 때마다 다시 실행하면 됩니다.

**1절 tfvars와의 관계:** 별도 설정 파일을 두지 않습니다. `terraform/`에서 **`terraform init`이 된 상태**이면 `img.sh`가 `terraform console`로 1절에서 정한 `aws_region`, `ecr_repo_ticketing_was`, `ecr_repo_worker_svc`, `image_tag`를 읽어 push 대상을 맞춥니다(apply 전이라도, init + tfvars만 있으면 됨). AWS 계정은 `aws sts get-caller-identity`(1절과 동일 자격증명)로 잡습니다.

한 번에 하는 일: ECR 로그인 → 두 서비스 디렉터리 각각 `docker build` → `docker push`.

이미지 참조 형태:

```text
<ACCOUNT_ID>.dkr.ecr.<aws_region>.amazonaws.com/<ecr_repo_* 경로>:<image_tag>
```

임시로만 바꿀 때는 환경변수로 덮어쓸 수 있습니다: `AWS_REGION`, `TAG`, `ECR_REPO_TICKETING_WAS`, `ECR_REPO_WORKER_SVC`.

### 2.3 정리: 한 줄로 이어지는 값

1절 tfvars에 **추가로 “이미지 URL 전용” 항목은 없습니다.** 아래 네 가지가 끝까지 같은 뜻으로 쓰입니다.

| tfvars 항목 | 역할 |
|-------------|------|
| `aws_region` | ECR/CLI 리전 |
| `ecr_repo_ticketing_was` / `ecr_repo_worker_svc` | 2.1 레포 이름, `img.sh` push 경로, Terraform·K8s 이미지의 레포 부분 |
| `image_tag` | 위 레포 안 태그 |

**흐름:** 1절에서 값 확정 → 2.1에서 그 이름으로 레포 생성 → `img.sh`로 같은 레포·태그에 push → `terraform apply` 등에서도 같은 tfvars로 Deployment 이미지 지정.

`terraform init`이 안 되어 `console`으로 변수를 못 읽는 경우에만 `img.sh`가 Terraform 변수 **기본값**(레포 `ticketing/...`, 태그 `latest` 등)으로 떨어질 수 있어, **1절 값을 쓰려면 `terraform init` 후 `img.sh`를 실행**하는 것이 맞습니다.

### 2.4 `scripts/img-alias.sh` (선택)

`img-alias.sh`는 `img.sh`를 호출하는 **`img` 별칭**만 등록합니다. 읽는 기준은 여전히 위와 같이 **`img.sh` → 1절 tfvars**이며, alias는 명령만 짧게 합니다.

**쓰는 법:** `source scripts/img-alias.sh` 또는 `~/.bashrc`에 `source "$TICKETING_REPO_ROOT/scripts/img-alias.sh"`(필요 시 `export TICKETING_REPO_ROOT=…` 먼저). 이후 같은 셸에서 `img` ≈ `bash …/scripts/img.sh`.

`bash scripts/img.sh`만 써도 동작은 동일합니다.

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