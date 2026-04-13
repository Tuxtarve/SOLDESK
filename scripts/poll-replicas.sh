#!/bin/bash
# Worker-svc replica + SQS 큐 길이 폴링
# 5초마다 CSV 한 줄 출력 → 파일로 redirect해서 그래프용
#
# 사용:
#   ./poll-replicas.sh > replicas.csv
#   (Ctrl+C로 종료)
set -e

NS="ticketing"
DEPLOY="worker-svc"
INTERVAL=${1:-5}
SQS_URL="https://sqs.ap-northeast-2.amazonaws.com/734772058616/ticketing-reservation.fifo"
REGION="ap-northeast-2"

echo "ts,replicas,ready,queue_visible,queue_in_flight"

while true; do
  TS=$(date +%s)
  R=$(kubectl get deploy -n "$NS" "$DEPLOY" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  READY=$(kubectl get deploy -n "$NS" "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  QATTR=$(aws sqs get-queue-attributes \
    --queue-url "$SQS_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --region "$REGION" \
    --query 'Attributes.[ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible]' \
    --output text 2>/dev/null || echo "0	0")
  QV=$(echo "$QATTR" | cut -f1)
  QIF=$(echo "$QATTR" | cut -f2)
  echo "${TS},${R:-0},${READY:-0},${QV:-0},${QIF:-0}"
  sleep "$INTERVAL"
done
