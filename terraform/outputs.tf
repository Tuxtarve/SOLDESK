output "cloudfront_domain" {
  value = module.cloudfront.cloudfront_domain
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_client_id" {
  value = module.cognito.user_pool_client_id
}

output "rds_writer_endpoint" {
  value     = module.rds.writer_endpoint
  sensitive = true
}

output "rds_reader_endpoint" {
  value     = module.rds.reader_endpoint
  sensitive = true
}

output "redis_endpoint" {
  value     = module.elasticache.redis_endpoint
  sensitive = true
}

output "sqs_queue_url" {
  value = module.sqs.reservation_queue_url
}

output "eks_cluster_name" {
  description = "Pass to kubectl: aws eks update-kubeconfig --region <region> --name $(terraform output -raw eks_cluster_name)"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC ID (AWS Load Balancer Controller --set vpcId)"
  value       = module.network.vpc_id
}

output "alb_controller_role_arn" {
  description = "IRSA role for aws-load-balancer-controller ServiceAccount"
  value       = module.eks.alb_controller_role_arn
}

output "cognito_user_pool_arn" {
  value = module.cognito.user_pool_arn
}

output "cognito_domain" {
  value = module.cognito.cognito_domain
}

output "aws_region" {
  value = var.aws_region
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role for cluster-autoscaler ServiceAccount"
  value       = module.eks.cluster_autoscaler_role_arn
}

output "keda_operator_role_arn" {
  description = "IRSA role for keda-operator ServiceAccount (SQS scaler)"
  value       = module.eks.keda_operator_role_arn
}

output "monitoring_ec2_ip" {
  value = module.monitoring.public_ip
}

output "monitoring_instance_id" {
  value = module.monitoring.instance_id
}

output "prometheus_url" {
  description = "Prometheus Web UI"
  value       = "http://${module.monitoring.public_ip}:9090"
}

output "grafana_url" {
  description = "Grafana Dashboard (root / soldesk1.)"
  value       = "http://${module.monitoring.public_ip}:3000"
}

output "alertmanager_url" {
  description = "Alertmanager Web UI"
  value       = "http://${module.monitoring.public_ip}:9093"
}

output "github_actions_role_arn" {
  value = module.cicd.github_actions_role_arn
}

output "api_gateway_endpoint" {
  description = "API Gateway HTTP API invoke URL — CloudFront origin으로 사용됨"
  value       = module.api_gateway.api_endpoint
}

output "api_gateway_endpoint_host" {
  description = "API Gateway 도메인만 (https:// 제외)"
  value       = module.api_gateway.api_endpoint_host
}
