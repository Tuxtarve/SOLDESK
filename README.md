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
# image_tag = "v1"

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

### 3.1 출력에 나온 수동 절차 (요약)

apply 출력에 `bash ../scripts/...` 형태로 나오면 **현재 디렉터리가 `terraform/`** 일 때 기준. 저장소 루트 기준으로 쓰려면 아래처럼.

```bash
bash scripts/normalize-line-endings.sh

export DB_USER=root
export DB_PASSWORD='<tfvars db_password 와 동일>'

bash k8s/scripts/apply-secrets-from-terraform.sh
kubectl apply -k k8s
bash k8s/scripts/sync-s3-endpoints-from-ingress.sh

kubectl -n ticketing patch cm ticketing-config --type merge -p '{"data":{"DB_NAME":"ticketing"}}'
kubectl -n ticketing rollout restart deploy/worker-svc
kubectl -n ticketing rollout restart deploy/read-api
```

`ticketing_namespace` 등을 tfvars에서 바꿨으면 **`terraform apply` 출력에 나온 `kubectl` 줄을 그대로** 쓰면 됨.

**참고 (한 줄)**

| 단계 | |
|------|--|
| `normalize-line-endings.sh` | CRLF → LF |
| `DB_*` | 시크릿 스크립트용 |
| `apply-secrets-from-terraform.sh` | Terraform output → Secret |
| `kubectl apply -k k8s` | 매니페스트 적용 |
| `sync-s3-endpoints-from-ingress.sh` | Ingress ALB → S3 `api-origin.js` |
| `patch` / `rollout restart` | ConfigMap·시크릿 반영 |

출력의 `zzzzzz_url`(또는 동일 역할 URL)로 S3 정적 사이트 확인.

---

## 디렉터리

```text
├── terraform/          # VPC·EKS·RDS·Redis·SQS·S3, k8s_bootstrap.tf
├── k8s/                # kustomize (read/write-api, worker, ingress …)
├── services/           # ticketing-was, worker-svc 소스
├── frontend/           # S3 소스
├── db-schema/          # create.sql, Insert.sql
└── scripts/            # img.sh, normalize-line-endings.sh 등
```

---

## 어디에 무엇이 있는지

| 영역 | 위치 |
|------|------|
| 인프라 루트 | `terraform/main.tf`, `terraform/modules/*` |
| apply 후 자동 | `terraform/k8s_bootstrap.tf` → `post_apply_k8s_bootstrap.sh` |
| 클러스터 매니페스트 | `k8s/` |
| API·워커 코드 | `services/ticketing-was`, `services/worker-svc` |
| WAS·워커 Python·pip 버전 | `services/ticketing-was/requirements.txt`, `services/worker-svc/requirements.txt`, 각 `Dockerfile` |
| 프론트 업로드 | `terraform/modules/s3_hosting`, `s3_hosting_source_dir` |
| DB 스키마(init 켜면) | `db-schema/`, `init_db_schema_via_k8s.sh` |
| 수동 bootstrap 모음 | `scripts/k8s-bootstrap-manual.sh` |
