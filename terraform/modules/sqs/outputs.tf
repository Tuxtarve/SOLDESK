output "reservation_queue_url" { value = aws_sqs_queue.reservation.url }
output "reservation_queue_arn" { value = aws_sqs_queue.reservation.arn }
output "reservation_dlq_arn"   { value = aws_sqs_queue.reservation_dlq.arn }

output "reservation_ui_queue_url" { value = aws_sqs_queue.reservation_ui.url }
output "reservation_ui_queue_arn" { value = aws_sqs_queue.reservation_ui.arn }
output "reservation_ui_dlq_arn"   { value = aws_sqs_queue.reservation_ui_dlq.arn }
