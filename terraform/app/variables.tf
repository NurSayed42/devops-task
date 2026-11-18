variable "environment" {
  description = "Deployment environment. Selects names, tags, the state file and the GitHub Environment allowed to deploy."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be \"staging\" or \"production\"."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "devops-task"
}

variable "instance_type" {
  description = "EC2 instance type. Must match var.architecture (e.g. t3.* for x86_64, t4g.* for arm64)."
  type        = string
  default     = "t3.micro"
}

variable "architecture" {
  description = "CPU architecture of the AMI. The image is built for both, so arm64 (Graviton) works too."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be \"x86_64\" or \"arm64\"."
  }
}

variable "root_volume_size_gb" {
  type    = number
  default = 16
}

variable "app_port" {
  description = "Port the app is published on (on the host and in the security group)."
  type        = number
  default     = 80
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the app port. Public service by default; narrow it for internal environments."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the app's container logs."
  type        = number

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts (e.g. 7, 14, 30, 90)."
  }
}

variable "app_log_level" {
  type    = string
  default = "INFO"
}

variable "ecr_repository_name" {
  description = "ECR repository created by the shared stack."
  type        = string
  default     = "devops-task-api"
}

variable "image_tag" {
  description = "Initial value of the release-image parameter (image tag started at boot). Leave empty to let the release pipeline do the first deploy."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose \"<environment>\" GitHub Environment may deploy here."
  type        = string
  default     = "NurSayed42/devops-task"
}
