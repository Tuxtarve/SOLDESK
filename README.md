# Ticketing (S3 프론트 + EKS API/worker, RDS·Redis·SQS, Terraform)

S3 정적 호스팅, EKS Ingress, RDS(MySQL), ElastiCache, SQS를 Terraform으로 묶은 프로젝트입니다.

---

## Apply 머신에 필요한 것 (PATH)

| 도구 | 메모 |
|------|------|
| `terraform` | |
| `aws` | EKS·RDS 등 |
| `kubectl` | DB 스키마 init, bootstrap |
| `helm` | ALB Controller |
| `bash` | `local-exec` |
| `mysql` (클라이언트) | **선택** — 기본 스키마 적용은 EKS 내 `mysql:8` Pod. 로컬 `init_db_schema.sh`·수동 검증용 |
| **Docker** (`docker`) | **필수** — `scripts/img.sh`로 WAS(`ticketing-was`)·워커 이미지를 빌드·ECR 푸시할 때 |

설치: [kubectl](https://kubernetes.io/docs/tasks/tools/) · [Helm](https://helm.sh/docs/intro/install/) · [Docker Engine](https://docs.docker.com/engine/install/)

**로컬 mysql (Red Hat 계열, 선택)**

```bash
dnf install -y mariadb
# 또는 mysql-community-client
mysql --version
```

**Docker (WAS·워커 이미지 — `img.sh`)**

`bash scripts/img.sh`는 `services/ticketing-was`, `services/worker-svc`에 대해 `docker build` / `docker push`를 실행합니다. **로컬에 Docker(또는 Docker 호환 CLI)가 있고**, `docker` 명령이 PATH에 있어야 합니다.

```bash
docker --version
docker info   # 데몬 동작 확인
```

**WAS·워커 앱 — 버전·의존성 (소스 기준)**

| 항목 | 위치 |
|------|------|
| pip 패키지·버전 고정 | **`services/ticketing-was/requirements.txt`** (read/write API 공통) |
| 워커 동일 스택 | `services/worker-svc/requirements.txt` |
| 이미지 안 Python | 각 `Dockerfile` → **`python:3.12-slim`** |

로컬에서 소스만 돌려볼 때도 **`requirements.txt`와 맞는 Python(3.12 권장)** + `pip install -r requirements.txt`를 쓰면 됨. 상세 버전은 **txt 파일이 기준** — README에 나열하지 않음(파일이 바뀌면 불일치 방지).

---


## 1. `terraform/terraform.tfvars`

자격증명: `~/.aws/config` · `~/.aws/credentials`(또는 SSO). 아래에서 **빈 값만** 채움.

```hcl
########################################
# 사용자 입력
########################################

db_password = ""
# db_password = "abc"

k8s_ingress_name = ""
# k8s_ingress_name = "my-ingress"

ecr_repo_ticketing_was = ""
# ecr_repo_ticketing_was = "myteam/ticketing-was"

ecr_repo_worker_svc = ""
# ecr_repo_worker_svc = "myteam/worker-svc"

image_tag = ""
# image_tag = "v1", "latest" 등

########################################
# 고정 예시 (필요 시 수정)
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

---

## 2. ECR · 이미지

`--region` 생략 시 프로필 region과 `aws_region`을 맞출 것.

### 2.1 레포 생성 (최초)

`<...>` 를 tfvars와 동일 문자열로 교체.

```bash
aws ecr create-repository --repository-name "<ecr_repo_ticketing_was>"
aws ecr create-repository --repository-name "<ecr_repo_worker_svc>"
aws ecr describe-repositories --query 'repositories[].repositoryName' --output table
```

이미 있으면 `RepositoryAlreadyExistsException` → 무시.

### 2.2 빌드 · 푸시

**Terraform `init` 불필요.** 순서: **이미지 → `apply`.**

```bash
bash scripts/img.sh
```

리전: `AWS_REGION` → `AWS_DEFAULT_REGION` → `aws configure get region` → `terraform/terraform.tfvars` 의 `aws_region`.  
덮어쓰기: `TAG`, `ECR_REPO_TICKETING_WAS`, `ECR_REPO_WORKER_SVC`.

이미지 URL 형태:

```text
<ACCOUNT>.dkr.ecr.<region>.amazonaws.com/<ecr_repo>:<image_tag>
```

tfvars에 레포/태그 없으면 스크립트 기본값(`ticketing/...`, `latest`).

### 2.3 `img` 별칭 (선택)

`img.sh` 와 동일.

```bash
source scripts/img-alias.sh
img
```

### 2.4 tfvars ↔ 이미지

| 키 | 쓰임 |
|----|------|
| `aws_region` | ECR·CLI |
| `ecr_repo_ticketing_was` / `ecr_repo_worker_svc` | ECR 이름 · `img.sh` · K8s 이미지 경로 |
| `image_tag` | 태그 |

---

## 3. Terraform

```bash
cd terraform
terraform init
terraform apply
```

`run_k8s_bootstrap_after_apply = true` 이면 apply 끝에 bootstrap 스크립트가 돈다.

### 3.1 `terraform apply` 이후 — 출력(zzzz) 따라가기

1. `terraform init`, `terraform apply`를 완료합니다.

2. `terraform apply`가 끝나면 **output**에 아래와 비슷한 블록이 나옵니다. `${var.ticketing_namespace}` 등은 실제 값으로 치환되어 출력됩니다.

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

3. **출력에 나온 명령을 그대로** 터미널에 붙여넣어 실행하는 것이 가장 안전합니다. (출력은 보통 **`terraform/` 디렉터리에서 실행한다고 가정**하고 `../scripts`, `../k8s` 경로를 씁니다.)

   아래는 **같은 순서**를 유지한 예시입니다. `terraform/` 에서 실행한다는 전제로 `../` 가 붙어 있습니다. **저장소 루트**에서 돌리려면 `../scripts` → `scripts`, `../k8s` → `k8s` 로 바꾸면 됩니다.

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

위 예시의 `ticketing`, `ticketing-config`, `worker-svc`, `read-api` 는 **tfvars 기본값**입니다. `ticketing_namespace`, `ticketing_configmap_name`, `*_deployment_name` 을 바꿨다면 **`terraform apply` 출력에 찍힌 `kubectl` 줄을 그대로** 쓰면 됩니다.

4. output 최하단의 **`zzzzzz_url`**(또는 동일 역할 URL)로 접속해 S3 정적 웹호스팅이 뜨는지 확인합니다.

---

# 구조 설명

```text
<저장소 루트>/
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
  - **Python·pip 버전**: `services/ticketing-was/requirements.txt`, `services/worker-svc/requirements.txt`, 각 `Dockerfile` (`python:3.12-slim`)

- **정적 프론트엔드**: `frontend/`
  - `terraform/modules/s3_hosting`가 `s3_hosting_source_dir`을 S3로 업로드해서 정적 호스팅합니다.

- **DB 스키마/시드**: `db-schema/`
  - `enable_db_schema_init = true`면, apply 중 `terraform/scripts/init_db_schema_via_k8s.sh`로 클러스터 내부에서 스키마/시드를 적용합니다.

- **로컬 편의 스크립트(수동 실행/보조)**: `scripts/`
  - **줄바꿈(CRLF) 정규화**: `scripts/normalize-line-endings.sh`
  - **이미지 빌드/푸시**: `scripts/img.sh`(또는 `source scripts/img-alias.sh` 후 `img`)
  - **수동 bootstrap(출력 zzzzz 따라가기)**: `scripts/k8s-bootstrap-manual.sh`
