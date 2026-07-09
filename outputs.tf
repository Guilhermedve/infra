output "bucket_name" { 
    value = data.aws_s3_bucket.bucket.id
    sensitive = false
    description = "The name of the S3 bucket created by this Terraform configuration."

}
output "region" { 
    value = data.aws_s3_bucket.bucket.region
    sensitive = false
    description = "The AWS region where the S3 bucket is located."
}