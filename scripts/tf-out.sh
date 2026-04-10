#!/usr/bin/env bash
# 저장소 어느 디렉터리에서 실행해도 terraform/ 기준으로 output 을 찍는다.
# 예: bash scripts/tf-out.sh frontend_website_url
set -euo pipefail
NAME="${1:?사용법: $0 <terraform_output_name> 예: frontend_website_url}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec terraform -chdir="$ROOT/terraform" output -raw "$NAME"
