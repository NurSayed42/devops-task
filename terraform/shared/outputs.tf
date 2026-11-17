output "ecr_repository_name" {
  value = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecr_push_role_arn" {
  description = "Set as the GitHub repository variable AWS_ECR_PUSH_ROLE_ARN."
  value       = aws_iam_role.ecr_push.arn
}

output "github_oidc_provider_arn" {
  value = local.github_oidc_provider_arn
}
