module "s3" {
  source                    = "./modules/s3"
  bucket_name               = "practice-cf-lab-${random_string.suffix.result}"
  cloudfront_distribution_arn = module.cloudfront.distribution_arn
}

module "cloudfront" {
  source                      = "./modules/cloudfront"
  bucket_regional_domain_name = module.s3.bucket_regional_domain_name
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}
