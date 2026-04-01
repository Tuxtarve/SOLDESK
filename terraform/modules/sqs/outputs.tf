output "reservation_queue_url" { value = aws_sqs_queue.reservation.url }
output "reservation_queue_arn" { value = aws_sqs_queue.reservation.arn }
output "reservation_dlq_arn" { value = aws_sqs_queue.reservation_dlq.arn }
output "sns_topic_arn" { value = aws_sns_topic.ticket_confirmed.arn }
output "sns_confirmed_arn" { value = aws_sns_topic.ticket_confirmed.arn }
output "sns_cancelled_arn" { value = aws_sns_topic.ticket_cancelled.arn }
output "sns_reminder_arn" { value = aws_sns_topic.event_reminder.arn }
