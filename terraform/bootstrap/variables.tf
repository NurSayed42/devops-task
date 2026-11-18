variable "aws_region" {
  description = "Region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as a prefix for resource names."
  type        = string
  default     = "devops-task"
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete the bucket even if it still holds state versions. Keep false outside of throwaway accounts."
  type        = bool
  default     = false
}
