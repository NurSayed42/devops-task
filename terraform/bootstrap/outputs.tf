output "state_bucket" {
  description = "Pass to the other stacks with: terraform init -backend-config=\"bucket=<this>\""
  value       = aws_s3_bucket.state.id
}

output "aws_region" {
  value = var.aws_region
}
