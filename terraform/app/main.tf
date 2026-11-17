locals {
  name = "${var.project}-${var.environment}"

  image_uri = var.image_tag == "" ? "" : "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"

  # Deterministic pick of a default subnet in an AZ that offers the instance type.
  subnet_id = sort(data.aws_subnets.default.ids)[0]
}

data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

# ---- Network: default VPC (acceptable for this task, see README) ----

data "aws_vpc" "default" {
  default = true
}

# Not every AZ offers every instance type (e.g. t3.micro in some older AZs).
data "aws_ec2_instance_type_offerings" "supported" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.supported.locations
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${local.name}-app-"
  description = "${local.name}: app port in; HTTPS out to AWS APIs and package repos"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${local.name}-app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Only the app port is open. There is deliberately no SSH rule: shell access
# goes through SSM Session Manager, which is IAM-authenticated and audited.
resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "App HTTP traffic"
  ip_protocol       = "tcp"
  from_port         = var.app_port
  to_port           = var.app_port
  cidr_ipv4         = each.value
}

# Everything the host talks to (ECR, S3 image layers, CloudWatch Logs, SSM,
# the Amazon Linux repos) is HTTPS. DNS, NTP and IMDS are link-local / VPC
# resolver traffic, which security groups don't filter.
#
# Accepted Trivy finding AWS-0104 (unrestricted egress): the destinations are
# public AWS service endpoints with large, changing IP ranges, so a CIDR
# allow-list is not maintainable; egress is already limited to tcp/443. The
# real fix is private subnets + VPC endpoints (ecr.api, ecr.dkr, s3, logs, ssm,
# ssmmessages, ec2messages): six interface endpoints at ~$7-8/month each cost
# several times this t3.micro. Revisit together with a dedicated VPC.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs and package repositories"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- Logs: the Docker awslogs driver ships container stdout here ----

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}/app"
  retention_in_days = var.log_retention_days
}
