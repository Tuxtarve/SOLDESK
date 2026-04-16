# ── DLQ: bulk/load-test 예약 큐용 ──
resource "aws_sqs_queue" "reservation_dlq" {
    name                        = "ticketing-reservation-dlq.fifo"
    fifo_queue                  = true
    content_based_deduplication = true
    message_retention_seconds   = 1209600

    tags = { Name = "ticketing-reservation-dlq", Environment = var.env }
}

# ── 메인 큐: bulk/load-test 예약 (worker-svc 소비) ──
resource "aws_sqs_queue" "reservation" {
    name                            = "ticketing-reservation.fifo"
    fifo_queue                      = true
    content_based_deduplication     = true
    visibility_timeout_seconds      = 60
    message_retention_seconds       = 86400
    receive_wait_time_seconds       = 20

    redrive_policy = jsonencode({
        deadLetterTargetArn = aws_sqs_queue.reservation_dlq.arn
        maxReceiveCount     = 3
    })

    tags = { Name = "ticketing-reservation", Environment = var.env }
}

# ── DLQ: UI 예약 큐용 ──
resource "aws_sqs_queue" "reservation_ui_dlq" {
    name                        = "ticketing-reservation-ui-dlq.fifo"
    fifo_queue                  = true
    content_based_deduplication = true
    message_retention_seconds   = 1209600

    tags = { Name = "ticketing-reservation-ui-dlq", Environment = var.env }
}

# ── UI 큐: 인터랙티브/UI 예약 (worker-svc 소비) ──
resource "aws_sqs_queue" "reservation_ui" {
    name                            = "ticketing-reservation-ui.fifo"
    fifo_queue                      = true
    content_based_deduplication     = true
    visibility_timeout_seconds      = 60
    message_retention_seconds       = 86400
    receive_wait_time_seconds       = 20

    redrive_policy = jsonencode({
        deadLetterTargetArn = aws_sqs_queue.reservation_ui_dlq.arn
        maxReceiveCount     = 3
    })

    tags = { Name = "ticketing-reservation-ui", Environment = var.env }
}
