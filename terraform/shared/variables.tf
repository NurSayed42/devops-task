variable "aws_region" {
  description = "Region for the ECR repository and IAM resources."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix for resource names."
  type        = string
  default     = "devops-task"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose main-branch workflows may push images."
  type        = string
  default     = "NurSayed42/devops-task"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like \"owner/name\"."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one (only one per URL is allowed)."
  type        = bool
  default     = true
}

variable "ecr_keep_images" {
  description = "Number of tagged images to keep in ECR; older ones are expired."
  type        = number
  default     = 30
}

variable "ecr_force_delete" {
  description = "Allow destroying the repository while it still contains images."
  type        = bool
  default     = false
}
