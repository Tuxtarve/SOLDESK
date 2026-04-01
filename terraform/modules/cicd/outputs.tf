output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
output "ecr_event_svc_url" { value = aws_ecr_repository.event_svc.repository_url }
output "ecr_reserv_svc_url" { value = aws_ecr_repository.reserv_svc.repository_url }
output "ecr_worker_svc_url" { value = aws_ecr_repository.worker_svc.repository_url }
output "ecr_frontend_url" { value = aws_ecr_repository.frontend.repository_url }
