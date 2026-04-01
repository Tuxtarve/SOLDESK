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

# SNS Topic (예매 완료/취소/리마인더 알림)
resource "aws_sns_topic" "ticket_confirmed" {
  name = "ticketing-ticket-confirmed"
  tags = { Name = "ticketing-ticket-confirmed", Environment = var.env }
}

resource "aws_sns_topic" "ticket_cancelled" {
  name = "ticketing-ticket-cancelled"
  tags = { Name = "ticketing-ticket-cancelled", Environment = var.env }
}

resource "aws_sns_topic" "event_reminder" {
  name = "ticketing-event-reminder"
  tags = { Name = "ticketing-event-reminder", Environment = var.env }
}

# EventBridge: 미결제 예약 만료 스케줄러 (10분마다)
resource "aws_cloudwatch_event_rule" "reservation_expiry" {
  name                = "ticketing-reservation-expiry"
  description         = "미결제 예약 만료 처리"
  schedule_expression = "rate(10 minutes)"
}
