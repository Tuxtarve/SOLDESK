resource "aws_sqs_queue" "reservation_dlq" {
  name                        = "ticketing-reservation-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600

  tags = { Name = "ticketing-reservation-dlq", Environment = var.env }
}

resource "aws_sqs_queue" "reservation" {
  name                        = "ticketing-reservation.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  # 워커: DB 커밋 + Redis 결과 저장 + 캐시 무효화까지 여유 (재전달 시 중복 위험 완화)
  visibility_timeout_seconds = 90
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.reservation_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "ticketing-reservation", Environment = var.env }
}

# GUI·write-api 전용 FIFO. 부하 스크립트·대량 적체는 ticketing-reservation.fifo 만 사용 →
# 사용자 예매 큐가 부하 큐에 묻히지 않음. 워커는 worker-svc( bulk ) / worker-svc-ui( interactive ) 로 분리.
resource "aws_sqs_queue" "reservation_interactive_dlq" {
  name                        = "ticketing-reservation-ui-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600

  tags = { Name = "ticketing-reservation-ui-dlq", Environment = var.env }
}

resource "aws_sqs_queue" "reservation_interactive" {
  name                        = "ticketing-reservation-ui.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = 90
  message_retention_seconds   = 86400
  receive_wait_time_seconds   = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.reservation_interactive_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "ticketing-reservation-ui", Environment = var.env }
}