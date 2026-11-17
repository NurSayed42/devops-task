resource "aws_ecr_repository" "app" {
  name = "${var.project}-api"

  # A tag always points to the same image, so "deploy 0.1.42" and "roll back
  # to 0.1.41" mean exactly what they say. This is also why we never push `latest`.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Only tagged images count: each release is one multi-arch index (with its
# semver + SHA tags). The untagged per-platform manifests it references must
# not be expired on their own or the index would break.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last ${var.ecr_keep_images} tagged releases"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["*"]
        countType      = "imageCountMoreThan"
        countNumber    = var.ecr_keep_images
      }
      action = {
        type = "expire"
      }
    }]
  })
}
