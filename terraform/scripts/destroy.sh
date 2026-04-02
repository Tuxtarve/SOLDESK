#!/usr/bin/env bash
# terraform destroy 래퍼 스크립트
# CloudFront OAC가 distribution 삭제 직후 AWS 내부 전파 지연으로 인해
# "OriginAccessControlInUse" 에러가 발생할 수 있으므로, 실패 시 자동 재시도한다.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAX_RETRIES=3
RETRY_WAIT=60

run_destroy() {
  terraform destroy "$@"
}

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo "=== destroy 시도 $attempt / $MAX_RETRIES ==="
  if run_destroy "$@"; then
    echo "=== destroy 완료 ==="
    exit 0
  fi

  if [ $attempt -lt $MAX_RETRIES ]; then
    echo "=== destroy 실패. ${RETRY_WAIT}초 후 재시도합니다... ==="
    sleep $RETRY_WAIT
  fi

  attempt=$((attempt + 1))
done

echo "=== destroy ${MAX_RETRIES}회 모두 실패했습니다. 에러를 확인하세요. ==="
exit 1
