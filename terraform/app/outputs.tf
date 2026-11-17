output "instance_id" {
  value = aws_instance.app.id
}

output "public_dns" {
  value = aws_instance.app.public_dns
}

output "app_url" {
  value = "http://${aws_instance.app.public_dns}${var.app_port == 80 ? "" : ":${var.app_port}"}"
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "deploy_role_arn" {
  description = "Set as AWS_DEPLOY_ROLE_ARN in the GitHub Environment named after var.environment."
  value       = aws_iam_role.deploy.arn
}

output "ssm_session_command" {
  description = "Shell on the host without SSH."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.app.id}"
}
