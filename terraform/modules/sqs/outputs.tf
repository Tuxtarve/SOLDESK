output "reservation_queue_url" { value = aws_sqs_queue.reservation.url }
output "reservation_queue_arn" { value = aws_sqs_queue.reservation.arn }
output "reservation_dlq_arn" { value = aws_sqs_queue.reservation_dlq.arn }

output "reservation_interactive_queue_url" { value = aws_sqs_queue.reservation_interactive.url }
output "reservation_interactive_queue_arn" { value = aws_sqs_queue.reservation_interactive.arn }
output "reservation_interactive_dlq_arn" { value = aws_sqs_queue.reservation_interactive_dlq.arn }
