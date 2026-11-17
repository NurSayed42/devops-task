# The image currently released to this environment. The pipeline writes it
# after a deploy passes its smoke test; a freshly (re)created host reads it at
# boot and starts that exact release, so replacing the server never leaves it
# empty or on a stale version.
resource "aws_ssm_parameter" "release_image" {
  name        = "/${var.project}/${var.environment}/release-image"
  description = "Image currently released to ${var.environment} (written by the release pipeline)"
  type        = "String"
  value       = local.image_uri != "" ? local.image_uri : "none"

  lifecycle {
    # Owned by the pipeline after creation; Terraform must not reset it.
    ignore_changes = [value]
  }
}
