# Dead Letter Queue (3회 실패 시 이동)
resource "aws_sqs_queue" "reservation_dlq" {
  name                        = "ticketing-reservation-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600 # 14일

  tags = { Name = "ticketing-reservation-dlq", Environment = var.env }
}

# 예매 메인 FIFO 큐
resource "aws_sqs_queue" "reservation" {
  name                        = "ticketing-reservation.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = 60
  message_retention_seconds   = 86400 # 1일
  receive_wait_time_seconds   = 20    # Long Polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.reservation_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "ticketing-reservation", Environment = var.env }
}
