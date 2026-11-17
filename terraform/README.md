# Terraform: AWS deployment target

Three small stacks, applied in order. Each has its own state so a mistake in
one environment can't touch another.

| Stack | State | Creates |
|-------|-------|---------|
| `bootstrap/` | local (one-off) | S3 bucket for remote state: versioned, encrypted, public access blocked, TLS-only |
| `shared/` | `s3://…/shared/terraform.tfstate` | ECR repository (immutable tags, scan on push, lifecycle), GitHub OIDC provider, ECR push role for CI |
| `app/` | `s3://…/app/<env>/terraform.tfstate` | Per environment: EC2 host, security group, instance role/profile, CloudWatch log group, GitHub deploy role |

`app/` is one piece of code for both environments. The environment is chosen by
`envs/<env>.tfvars` (sizes, log retention, log level) plus
`envs/<env>.s3.tfbackend` (state key).

## Prerequisites

- Terraform >= 1.10 (CI uses 1.17.2). 1.10+ is needed for S3-native state locking.
- AWS CLI v2, logged in as an identity that can create IAM, EC2, ECR, S3 and Logs resources.
  This identity is only for applying the infrastructure. CI uses OIDC roles, never access keys.

## Apply

```bash
export AWS_REGION=ap-south-1
STATE_BUCKET="devops-task-tfstate-$(aws sts get-caller-identity --query Account --output text)"

# 1. State bucket (once per account)
cd terraform/bootstrap
terraform init
terraform apply

# 2. ECR + GitHub OIDC (once per account)
cd ../shared
terraform init -backend-config="bucket=${STATE_BUCKET}"
terraform plan -out=tfplan
terraform apply tfplan
# If the account already has a GitHub OIDC provider: add -var=create_github_oidc_provider=false

# 3. Staging
cd ../app
terraform init -backend-config=envs/staging.s3.tfbackend -backend-config="bucket=${STATE_BUCKET}"
terraform plan -var-file=envs/staging.tfvars -out=tfplan
terraform apply tfplan

# 4. Production: same code, different state file and variables
terraform init -reconfigure -backend-config=envs/production.s3.tfbackend -backend-config="bucket=${STATE_BUCKET}"
terraform plan -var-file=envs/production.tfvars -out=tfplan
terraform apply tfplan
```

On the first apply ECR is still empty, so the instance only installs Docker and
waits. The release pipeline does the first deploy. To start a specific image at
boot instead, pass `-var=image_tag=<tag>`.

Commit the generated `.terraform.lock.hcl` files, so every machine and CI run
uses the same provider build.

## Check it

```bash
terraform output app_url                         # then: curl "$(terraform output -raw app_url)/health"
aws logs tail "$(terraform output -raw log_group_name)" --follow
$(terraform output -raw ssm_session_command)     # shell on the host, no SSH needed
sudo cat /var/log/devops-task-bootstrap.log      # (on the host) user-data output
```

## Destroy

Reverse order. ECR and the state bucket refuse to delete non-empty resources
by default.

```bash
cd terraform/app        # once per environment (re-init with that env's backend)
terraform destroy -var-file=envs/staging.tfvars

cd ../shared
terraform apply -var=ecr_force_delete=true && terraform destroy -var=ecr_force_delete=true

cd ../bootstrap
terraform apply -var=force_destroy=true && terraform destroy -var=force_destroy=true
```

## Design notes

**State.** S3 with versioning (recover a bad state), SSE, public access blocked,
a bucket policy that denies non-TLS access, and old versions expiring after
90 days. Locking uses S3's conditional writes (`use_lockfile = true`), so no
DynamoDB table is needed. Since Terraform 1.11 that is the recommended
mechanism. The bootstrap stack keeps local state because it creates the
bucket everything else depends on.

**Least privilege.**

| Principal | Can do | Scope |
|-----------|--------|-------|
| EC2 instance role | pull images | the one ECR repo (plus `GetAuthorizationToken`, which has no resource scoping) |
| | write logs | its own environment's log group only, and no `CreateLogGroup` |
| | be managed by SSM | `AmazonSSMManagedInstanceCore` (Run Command for deploys, Session Manager instead of SSH) |
| CI push role | push images | the one ECR repo; assumable only from `refs/heads/main` of this repo |
| CI deploy role (per env) | `ssm:SendCommand` | that environment's instance and the `AWS-RunShellScript` document only; assumable only from the matching GitHub Environment |

No static access keys exist anywhere: CI uses OIDC, and the host uses its
instance profile.

**Network.** Default VPC (accepted by the task; a real setup would use a
dedicated VPC with private subnets behind an ALB). Ingress is only the app
port. There is no SSH rule, because Session Manager covers shell access. Egress
is only 443, since ECR, S3, CloudWatch, SSM and the Amazon Linux repos are all
HTTPS. IMDSv2 is required, with hop limit 1 so containers cannot reach the
instance credentials.

**Host lifecycle.** Changing the user data replaces the instance
(`user_data_replace_on_change`): hosts are rebuilt, not patched in place.
`ignore_changes = [ami]` stops a new Amazon Linux release from replacing the
server on an unrelated plan. AMI updates are a deliberate `-replace`.
T-family instances use `standard` CPU credits, so a CPU spike throttles
instead of billing "unlimited" surplus credits.

**Logs.** Docker's `awslogs` driver ships container stdout (already JSON) to
`/devops-task/<env>/app`. Retention is 7 days in staging and 30 days in
production. The driver runs in non-blocking mode, so a CloudWatch hiccup
can't stall the app.
