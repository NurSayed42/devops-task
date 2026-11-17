# Amazon Linux 2023: SSM agent and AWS CLI preinstalled, Docker from the
# distro repo, security updates from AWS.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_ami.insecure_value
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  monitoring             = false # 5-min basic metrics are enough here; detailed monitoring costs extra

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    environment       = var.environment
    aws_region        = var.aws_region
    log_level         = var.app_log_level
    log_group         = aws_cloudwatch_log_group.app.name
    host_port         = var.app_port
    image_uri         = local.image_uri
    deploy_script_b64 = base64encode(file("${path.module}/../../scripts/deploy.sh"))
  })
  # Bootstrap changes take effect by replacing the host (immutable server).
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # Hop limit 1: processes on the host (dockerd, aws cli) reach IMDS, but
    # containers behind the Docker bridge cannot, so they can't take the role.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  # T-family defaults to "unlimited" CPU credits, which can bill surprise
  # surplus charges. "standard" throttles instead.
  dynamic "credit_specification" {
    for_each = startswith(var.instance_type, "t") ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  tags = {
    Name = local.name
  }

  lifecycle {
    # A new AL2023 release should not replace the server on the next plan;
    # AMI updates are rolled out deliberately (taint/replace).
    ignore_changes = [ami]
  }
}
