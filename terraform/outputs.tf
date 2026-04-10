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
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "alb_controller_role_arn" {
  value = module.eks.alb_controller_role_arn
}

output "cluster_autoscaler_role_arn" {
  value = module.eks.cluster_autoscaler_role_arn
}

output "sqs_access_role_arn" {
  value = module.eks.sqs_access_role_arn
}

output "aws_region" {
  value = var.aws_region
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "frontend_bucket_name" {
  description = "Frontend static site bucket name (v2 module)."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.frontend_bucket_name : null
}

output "frontend_website_url" {
  description = "Frontend static site website URL (v2 module)."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.frontend_website_url : null
}

output "zzzzzz_url" {
  description = "Same as frontend_website_url."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.frontend_website_url : null
}

output "frontend_cloudfront_url" {
  description = "CloudFront URL for frontend (v2 module)."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.cloudfront_url : null
}

output "zzzzz" {
  description = "Commands to run after apply."
  value       = <<-EOT

  .............................

  export DB_USER=root
  export DB_PASSWORD=

  bash ../scripts/normalize-line-endings.sh
  bash ../k8s/scripts/apply-secrets-from-terraform.sh
  kubectl apply -k ../k8s
  bash ../k8s/scripts/sync-s3-endpoints-from-ingress.sh
  kubectl -n ${var.ticketing_namespace} patch cm ${var.ticketing_configmap_name} --type merge -p '{"data":{"DB_NAME":"ticketing"}}'
  kubectl -n ${var.ticketing_namespace} rollout restart deploy/${var.worker_deployment_name}
  kubectl -n ${var.ticketing_namespace} rollout restart deploy/${var.read_api_deployment_name}

  .............................
  EOT
}
