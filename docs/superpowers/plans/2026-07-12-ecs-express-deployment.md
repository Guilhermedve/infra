# ECS Express Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the invalid App Runner attempt with a cost-controlled ECS Express service and deploy every successful `main` build from GitHub Actions using immutable ECR image tags.

**Architecture:** Terraform AWS Provider 6.33.0 manages two ECS service roles, one ECS Express gateway service, its log group, ECR lifecycle retention, and two cost budgets. GitHub Actions keeps OIDC and ECR publishing, then updates the ECS Express primary container to the exact commit SHA and monitors the rollout.

**Tech Stack:** Terraform 1.15.x, HashiCorp AWS Provider 6.33.0, Amazon ECS Express Mode on Fargate, Amazon ECR, CloudWatch Logs, AWS Budgets, GitHub Actions, NestJS 11, Docker.

## Global Constraints

- Region remains `us-east-2`.
- Existing ECR repository `rocketseat-ci` must not be replaced.
- Existing GitHub OIDC trust subject remains `repo:Guilhermedve@217589707/infra@1295787607:ref:refs/heads/main`.
- Pull requests must never authenticate to AWS, publish images, or deploy.
- Images use immutable `${{ github.sha }}` tags; do not deploy `latest`.
- ECS Express uses `256` CPU units, `512` MiB memory, minimum `1` task, and maximum `2` tasks.
- The application listens on port `3000` and initially uses `/` for health checks.
- Budget notification email is supplied locally and must never be committed.
- Terraform state remains local and ignored by Git.
- Do not apply or destroy AWS infrastructure without explicit user approval at the execution checkpoint.
- Preserve unrelated user changes; `iac/iam.tf` currently contains the invalid, uncommitted App Runner attempt that Task 2 intentionally replaces.

---

### Task 1: Upgrade the Terraform AWS Provider

**Files:**
- Modify: `iac/main.tf`
- Modify mechanically: `iac/.terraform.lock.hcl`

**Interfaces:**
- Consumes: Terraform CLI `1.15.x` and the existing AWS provider configuration for `us-east-2`.
- Produces: AWS Provider `6.33.0`, which exposes `aws_ecs_express_gateway_service` to later tasks.

- [ ] **Step 1: Record the expected failing capability check**

Run:

```powershell
terraform -chdir=iac providers schema -json | Select-String 'aws_ecs_express_gateway_service'
```

Expected before the upgrade: no match because the lock file pins AWS Provider `5.49.0`.

- [ ] **Step 2: Raise the exact provider version**

Replace the provider block in `iac/main.tf` with:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.33.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}
```

- [ ] **Step 3: Refresh the provider lock file**

Run:

```powershell
terraform -chdir=iac init -upgrade
```

Expected: provider `registry.terraform.io/hashicorp/aws v6.33.0` is installed and `iac/.terraform.lock.hcl` records `6.33.0`.

- [ ] **Step 4: Prove the ECS Express resource is now available**

Run:

```powershell
terraform -chdir=iac providers schema -json | Select-String 'aws_ecs_express_gateway_service'
terraform -chdir=iac validate
```

Expected: the resource name matches. Validation can still fail on the user's invalid App Runner block; that specific failure is removed in Task 2.

- [ ] **Step 5: Commit the provider upgrade**

```powershell
git add -- iac/main.tf iac/.terraform.lock.hcl
git commit -m "chore: upgrade AWS provider for ECS Express"
```

---

### Task 2: Replace App Runner IAM with ECS Express Roles

**Files:**
- Modify: `iac/iam.tf`

**Interfaces:**
- Consumes: the approved immutable GitHub OIDC trust already present in `iac/iam.tf`.
- Produces: `aws_iam_role.ecs_task_execution`, `aws_iam_role.ecs_express_infrastructure`, and their managed-policy attachments for Task 3.

- [ ] **Step 1: Capture the current syntax failure**

Run:

```powershell
terraform -chdir=iac validate
```

Expected before replacement: failure near the invalid `manage_policy_arns` App Runner block.

- [ ] **Step 2: Remove only the invalid App Runner block**

Delete the complete `resource "aws_iam_role" "app-runner-role"` block. Do not modify `aws_iam_openid_connect_provider.openidgit`, `aws_iam_role.github_actions`, or its immutable `sub` condition.

- [ ] **Step 3: Add the ECS task execution role**

Insert before `aws_iam_role.github_actions`:

```hcl
resource "aws_iam_role" "ecs_task_execution" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
```

- [ ] **Step 4: Add the ECS Express infrastructure role**

Insert immediately after the task execution attachment:

```hcl
resource "aws_iam_role" "ecs_express_infrastructure" {
  name = "ecsInfrastructureRoleForExpressServices"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccessInfrastructureForECSExpressServices"
        Effect = "Allow"
        Principal = {
          Service = "ecs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_express_infrastructure" {
  role       = aws_iam_role.ecs_express_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}
```

- [ ] **Step 5: Format and validate the IAM replacement**

Run:

```powershell
terraform -chdir=iac fmt
terraform -chdir=iac validate
git diff --check
```

Expected: all commands exit `0`; no `apprunner.amazonaws.com` string remains.

- [ ] **Step 6: Commit the IAM roles**

```powershell
git add -- iac/iam.tf
git commit -m "feat: add ECS Express service roles"
```

---

### Task 3: Define the Cost-Controlled ECS Express Service

**Files:**
- Create: `iac/variables.tf`
- Create: `iac/ecs-express.tf`
- Create: `iac/outputs.tf`

**Interfaces:**
- Consumes: ECR repository URL, ECS execution role ARN, ECS infrastructure role ARN, and an existing image tag supplied as `initial_image_tag`.
- Produces: `aws_ecs_express_gateway_service.app`, output `ecs_express_service_arn`, and output `ecs_express_ingress_paths` for deployment and operations.

- [ ] **Step 1: Add validated inputs**

Create `iac/variables.tf`:

```hcl
variable "initial_image_tag" {
  description = "Existing immutable ECR image tag used for the first ECS Express deployment."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.initial_image_tag)) > 0 && var.initial_image_tag != "latest"
    error_message = "initial_image_tag must be a non-empty immutable tag and cannot be latest."
  }
}

variable "budget_alert_email" {
  description = "Operator email address that receives AWS Budget notifications."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}
```

- [ ] **Step 2: Add default-network preflight data and log retention**

Create `iac/ecs-express.tf` with:

```hcl
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/express/infra-project-name"
  retention_in_days = 7
}

resource "aws_ecs_express_gateway_service" "app" {
  service_name            = "infra-project-name"
  execution_role_arn      = aws_iam_role.ecs_task_execution.arn
  infrastructure_role_arn = aws_iam_role.ecs_express_infrastructure.arn
  cpu                     = "256"
  memory                  = "512"
  health_check_path       = "/"
  wait_for_steady_state   = true

  primary_container {
    image          = "${aws_ecr_repository.test.repository_url}:${var.initial_image_tag}"
    container_port = 3000

    aws_logs_configuration {
      log_group        = aws_cloudwatch_log_group.app.name
      log_stream_prefix = "app"
    }

    environment {
      name  = "NODE_ENV"
      value = "production"
    }

    environment {
      name  = "PORT"
      value = "3000"
    }
  }

  scaling_target {
    auto_scaling_metric       = "CPU"
    auto_scaling_target_value = 60
    min_task_count            = 1
    max_task_count            = 2
  }

  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.default.ids) >= 2
      error_message = "ECS Express requires at least two subnets in the default VPC."
    }
  }

  tags = {
    Application = "infra-project-name"
    ManagedBy   = "Terraform"
  }
}
```

- [ ] **Step 3: Add operational outputs**

Create `iac/outputs.tf`:

```hcl
output "ecs_express_service_arn" {
  description = "ARN stored as the GitHub repository variable ECS_EXPRESS_SERVICE_ARN."
  value       = aws_ecs_express_gateway_service.app.service_arn
}

output "ecs_express_ingress_paths" {
  description = "AWS-managed HTTPS ingress endpoints for the ECS Express service."
  value       = aws_ecs_express_gateway_service.app.ingress_paths
}

output "ecr_repository_url" {
  description = "Private ECR repository used by the deployment workflow."
  value       = aws_ecr_repository.test.repository_url
}
```

- [ ] **Step 4: Verify validation rejects mutable tags**

Run:

```powershell
terraform -chdir=iac validate
terraform -chdir=iac plan -input=false -var='initial_image_tag=latest' -var='budget_alert_email=operator@example.com'
```

Expected: validation succeeds; plan fails with `initial_image_tag ... cannot be latest` before proposing infrastructure changes.

- [ ] **Step 5: Verify formatting and commit**

```powershell
terraform -chdir=iac fmt
terraform -chdir=iac validate
git diff --check
git add -- iac/variables.tf iac/ecs-express.tf iac/outputs.tf
git commit -m "feat: define ECS Express service"
```

---

### Task 4: Add ECR Retention and Budget Guardrails

**Files:**
- Modify: `iac/ecr.tf`
- Create: `iac/budget.tf`
- Modify: `.gitignore`
- Configure locally, never commit: `TF_VAR_initial_image_tag` and `TF_VAR_budget_alert_email`

**Interfaces:**
- Consumes: `var.budget_alert_email` and the existing ECR repository.
- Produces: bounded ECR storage and actual/forecasted budget alerts at USD 10, 25, and 50.

- [ ] **Step 1: Add the ECR lifecycle policy**

Append to `iac/ecr.tf`:

```hcl
resource "aws_ecr_lifecycle_policy" "test" {
  repository = aws_ecr_repository.test.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 20 most recent tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPatternList = ["*"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged images after seven days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
```

- [ ] **Step 2: Add actual-spend budget notifications**

Create `iac/budget.tf` beginning with:

```hcl
locals {
  budget_thresholds = [10, 25, 50]
}

resource "aws_budgets_budget" "actual" {
  name         = "infra-actual-monthly-cost"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = toset(local.budget_thresholds)

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}
```

- [ ] **Step 3: Add forecasted-spend budget notifications**

Append to `iac/budget.tf`:

```hcl
resource "aws_budgets_budget" "forecasted" {
  name         = "infra-forecasted-monthly-cost"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = toset(local.budget_thresholds)

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}
```

- [ ] **Step 4: Protect local variable files**

Append to `.gitignore`:

```gitignore

# Terraform input files may contain notification addresses or secrets
*.tfvars
*.tfvars.json
```

Set the Terraform inputs only in the current PowerShell process:

```powershell
$env:TF_VAR_initial_image_tag = aws ecr describe-images --region us-east-2 --repository-name rocketseat-ci --query 'reverse(sort_by(imageDetails,& imagePushedAt))[0].imageTags[0]' --output text
$env:TF_VAR_budget_alert_email = Read-Host 'Budget notification email'
```

Expected: the image tag is an existing immutable ECR tag and the email remains only in the process environment. Do not print the email or write it to a tracked file.

- [ ] **Step 5: Validate and commit only safe files**

```powershell
terraform -chdir=iac fmt
terraform -chdir=iac validate
git diff --check
git add -- .gitignore iac/ecr.tf iac/budget.tf
git commit -m "feat: add deployment cost guardrails"
```

Expected: no `.tfvars` file is present in `git status --short`.

---

### Task 5: Grant GitHub the Minimum ECS Deployment Permissions

**Files:**
- Modify: `iac/iam.tf`

**Interfaces:**
- Consumes: `aws_ecs_express_gateway_service.app.service_arn` from Task 3.
- Produces: GitHub OIDC permission to update and observe only `infra-project-name`.

- [ ] **Step 1: Add the ECS statement to the existing inline policy**

Inside the `Statement` array in `aws_iam_role_policy.ecr_app_permission.policy`, keep the existing ECR statement and append:

```hcl
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeExpressGatewayService",
          "ecs:UpdateExpressGatewayService",
        ]
        Resource = aws_ecs_express_gateway_service.app.service_arn
      }
```

The complete `Statement` array must contain exactly the existing ECR push statement plus this ECS Express statement.

- [ ] **Step 2: Validate dependency and least-privilege scope**

Run:

```powershell
terraform -chdir=iac fmt
terraform -chdir=iac validate
rg -n 'ecs:|Resource = aws_ecs_express_gateway_service.app.service_arn' iac/iam.tf
```

Expected: only `DescribeExpressGatewayService` and `UpdateExpressGatewayService` are granted, scoped to the Terraform service ARN.

- [ ] **Step 3: Commit the deployment permissions**

```powershell
git add -- iac/iam.tf
git commit -m "feat: allow OIDC role to deploy ECS Express"
```

---

### Task 6: Add Automatic ECS Express Deployment to GitHub Actions

**Files:**
- Modify: `.github/workflows/main.yml`

**Interfaces:**
- Consumes: GitHub repository variable `ECS_EXPRESS_SERVICE_ARN`, ECR login output, and `${{ github.sha }}`.
- Produces: automatic monitored rollout of the immutable image on pushes to `main`.

- [ ] **Step 1: Add a preflight for the repository variable**

Insert after `Configure AWS credentials`:

```yaml
      - name: Validate deployment configuration
        if: github.event_name == 'push'
        env:
          ECS_EXPRESS_SERVICE_ARN: ${{ vars.ECS_EXPRESS_SERVICE_ARN }}
        run: |
          if [ -z "$ECS_EXPRESS_SERVICE_ARN" ]; then
            echo "Repository variable ECS_EXPRESS_SERVICE_ARN is required" >&2
            exit 1
          fi
```

- [ ] **Step 2: Add the monitored deployment after ECR push**

Append after `Push Docker image`:

```yaml
      - name: Deploy ECS Express service
        if: github.event_name == 'push'
        env:
          ECS_EXPRESS_SERVICE_ARN: ${{ vars.ECS_EXPRESS_SERVICE_ARN }}
          REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          REPOSITORY: rocketseat-ci
          IMAGE_TAG: ${{ github.sha }}
        run: |
          IMAGE_URI="$REGISTRY/$REPOSITORY:$IMAGE_TAG"
          PRIMARY_CONTAINER="$(jq -cn --arg image "$IMAGE_URI" '{image:$image,containerPort:3000,awsLogsConfiguration:{logGroup:"/ecs/express/infra-project-name",logStreamPrefix:"app"},environment:[{name:"NODE_ENV",value:"production"},{name:"PORT",value:"3000"}]}')"
          aws ecs update-express-gateway-service \
            --service-arn "$ECS_EXPRESS_SERVICE_ARN" \
            --primary-container "$PRIMARY_CONTAINER" \
            --monitor-resources
```

- [ ] **Step 3: Parse and inspect the complete workflow**

Run:

```powershell
npx --prefix project-name prettier --check ../.github/workflows/main.yml
git diff --check
Select-String -Path .github/workflows/main.yml -Pattern 'pull_request|github.event_name|ECS_EXPRESS_SERVICE_ARN|github.sha'
```

Expected: Prettier parses the YAML; every AWS/deploy step remains guarded by `github.event_name == 'push'`.

- [ ] **Step 4: Commit the workflow**

```powershell
git add -- .github/workflows/main.yml
git commit -m "feat: deploy ECS Express from main"
```

---

### Task 7: Document Apply, Rollback, Cost Monitoring, and Destroy

**Files:**
- Create: `docs/runbooks/ecs-express-operations.md`

**Interfaces:**
- Consumes: Terraform outputs and GitHub repository variable from earlier tasks.
- Produces: operator commands for initial creation, verification, rollback, and complete cost shutdown.

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/ecs-express-operations.md` with these exact sections and commands:

````markdown
# ECS Express Operations

## Prerequisites

- AWS CLI authenticated to account `236578428540`.
- Terraform variables supplied through `TF_VAR_initial_image_tag` and `TF_VAR_budget_alert_email` in the current process.
- Docker image tag in `initial_image_tag` already exists in `rocketseat-ci`.

## Initial plan and apply

```powershell
aws sts get-caller-identity
$imageTag = aws ecr describe-images --region us-east-2 --repository-name rocketseat-ci --query 'reverse(sort_by(imageDetails,& imagePushedAt))[0].imageTags[0]' --output text
aws ecr describe-images --region us-east-2 --repository-name rocketseat-ci --image-ids "imageTag=$imageTag"
$defaultVpcId = aws ec2 describe-vpcs --region us-east-2 --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text
aws ec2 describe-subnets --region us-east-2 --filters "Name=vpc-id,Values=$defaultVpcId"
terraform -chdir=iac init -upgrade
terraform -chdir=iac plan -out=ecs-express.tfplan
terraform -chdir=iac show -no-color ecs-express.tfplan
terraform -chdir=iac apply ecs-express.tfplan
terraform -chdir=iac output ecs_express_service_arn
terraform -chdir=iac output -json ecs_express_ingress_paths
```

Review the saved plan before apply. Apply only after confirming no existing ECR repository or GitHub OIDC resource will be replaced.

Set GitHub repository variable `ECS_EXPRESS_SERVICE_ARN` to the unquoted `ecs_express_service_arn` output.

## Verify

```powershell
$serviceArn = terraform -chdir=iac output -raw ecs_express_service_arn
$endpoint = Read-Host 'HTTPS endpoint shown in ecs_express_ingress_paths'
aws ecs describe-express-gateway-service --region us-east-2 --service-arn $serviceArn
Invoke-WebRequest -UseBasicParsing $endpoint
```

Expected: service status is `ACTIVE` and the HTTPS request returns HTTP 200.

## Roll back

```powershell
$registry = '236578428540.dkr.ecr.us-east-2.amazonaws.com'
$lastKnownGoodSha = Read-Host 'Last known-good commit SHA'
$serviceArn = terraform -chdir=iac output -raw ecs_express_service_arn
$image = "$registry/rocketseat-ci:$lastKnownGoodSha"
$primary = @{
  image = $image
  containerPort = 3000
  awsLogsConfiguration = @{
    logGroup = '/ecs/express/infra-project-name'
    logStreamPrefix = 'app'
  }
  environment = @(
    @{ name = 'NODE_ENV'; value = 'production' },
    @{ name = 'PORT'; value = '3000' }
  )
} | ConvertTo-Json -Depth 4 -Compress
aws ecs update-express-gateway-service --region us-east-2 --service-arn $serviceArn --primary-container $primary --monitor-resources
```

## Monitor cost

Check AWS Billing and Cost Management after each deployment. Investigate immediately when actual or forecasted alerts reach USD 10, USD 25, or USD 50.

## Destroy before credits expire

```powershell
terraform -chdir=iac plan -destroy -out=destroy.tfplan
terraform -chdir=iac show -no-color destroy.tfplan
terraform -chdir=iac apply destroy.tfplan
```

Confirm that the ECS Express service, Fargate tasks, and managed load balancer are gone. Preserve ECR only if images are still needed; otherwise destroy it through a separately reviewed plan.
````

- [ ] **Step 2: Check the runbook contains no real email, credential, or placeholder secret**

Run:

```powershell
rg -n -i 'AKIA|secret_access_key|password|@gmail|@outlook' docs/runbooks/ecs-express-operations.md
```

Expected: no match.

- [ ] **Step 3: Commit the runbook**

```powershell
git add -- docs/runbooks/ecs-express-operations.md
git commit -m "docs: add ECS Express operations runbook"
```

---

### Task 8: Run the Pre-Apply Verification Gate

**Files:**
- Verify only: all files changed by Tasks 1–7

**Interfaces:**
- Consumes: completed Terraform, workflow, NestJS app, Dockerfile, and runbook.
- Produces: evidence that the repository is safe to plan against AWS.

- [ ] **Step 1: Run local application gates**

```powershell
npm --prefix project-name run build
npm --prefix project-name test -- --runInBand
```

Expected: Nest build exits `0`; Jest reports `1 passed` and `0 failed`.

- [ ] **Step 2: Run infrastructure and workflow gates**

```powershell
terraform -chdir=iac fmt -check -recursive
terraform -chdir=iac validate
npx --prefix project-name prettier --check ../.github/workflows/main.yml
git diff --check
git status --short --branch
```

Expected: all checks exit `0`; only ignored local state remains outside Git.

- [ ] **Step 3: Run Docker verification when Docker Desktop is available**

```powershell
docker build -t infra-project-name:verify -f project-name/Dockerfile .
```

Expected: production image builds successfully. If Docker Desktop is unavailable, record this as an explicit unverified gate and do not claim Docker verification passed.

- [ ] **Step 4: Confirm no secrets or Terraform artifacts are tracked**

```powershell
git ls-files | Select-String -Pattern '(^|/)\.terraform/|terraform\.tfstate|\.tfvars$|\.tfplan$'
git grep -n -E 'AKIA[0-9A-Z]{16}|aws_secret_access_key|BEGIN (RSA|OPENSSH) PRIVATE KEY'
```

Expected: both commands return no matches.

- [ ] **Step 5: Commit only mechanical verification fixes if required**

If formatting modified files, stage only those exact files, rerun the full gate, and commit:

```powershell
git commit -m "style: normalize ECS Express configuration"
```

Do not create an empty commit.

---

### Task 9: Plan and Apply AWS Infrastructure at an Approval Checkpoint

**Files:**
- Local-only output: `iac/ecs-express.tfplan`

**Interfaces:**
- Consumes: real `iac/terraform.tfvars`, authenticated AWS operator session, and an existing immutable ECR image.
- Produces: deployed ECS Express service, budget alerts, and outputs required by GitHub Actions.

- [ ] **Step 1: Export the AWS login credentials into the current PowerShell process without printing them**

Run interactively:

```powershell
aws login
aws configure export-credentials --format powershell | Invoke-Expression
aws sts get-caller-identity
```

Expected: account is exactly `236578428540`. Stop if another account is shown.

- [ ] **Step 2: Run AWS preflight**

```powershell
$imageTag = aws ecr describe-images --region us-east-2 --repository-name rocketseat-ci --query 'reverse(sort_by(imageDetails,& imagePushedAt))[0].imageTags[0]' --output text
aws ecr describe-images --region us-east-2 --repository-name rocketseat-ci --image-ids "imageTag=$imageTag"
$defaultVpcId = aws ec2 describe-vpcs --region us-east-2 --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text
aws ec2 describe-subnets --region us-east-2 --filters "Name=vpc-id,Values=$defaultVpcId"
```

Expected: the image exists, one default VPC exists, and at least two subnets are returned.

- [ ] **Step 3: Create and review a saved Terraform plan**

```powershell
terraform -chdir=iac plan -out=ecs-express.tfplan
terraform -chdir=iac show -no-color ecs-express.tfplan
```

Expected: no ECR repository replacement, no GitHub OIDC provider replacement, and no deletion outside the invalid/unapplied App Runner attempt.

- [ ] **Step 4: Stop for explicit user approval**

Present the plan summary, expected monthly cost, resources created, and any deletions. Do not apply until the user explicitly authorizes this exact AWS infrastructure change.

- [ ] **Step 5: Apply the reviewed plan**

After approval:

```powershell
terraform -chdir=iac apply ecs-express.tfplan
terraform -chdir=iac output ecs_express_service_arn
terraform -chdir=iac output -json ecs_express_ingress_paths
```

Expected: apply exits `0`, service becomes steady, and outputs contain the service ARN and HTTPS ingress information.

---

### Task 10: Connect GitHub and Prove Deploy and Rollback

**Files:**
- No repository file changes expected
- External setting: GitHub repository variable `ECS_EXPRESS_SERVICE_ARN`

**Interfaces:**
- Consumes: applied service ARN and the committed deployment workflow.
- Produces: successful automatic deployment and tested rollback.

- [ ] **Step 1: Set the GitHub repository variable through an authenticated GitHub surface**

Set `ECS_EXPRESS_SERVICE_ARN` to the exact Terraform output. If GitHub CLI is unavailable, use repository Settings → Secrets and variables → Actions → Variables. This value is an ARN, not a secret.

- [ ] **Step 2: Publish the implementation branch or commit to `main`**

Confirm `git status --short --branch` is clean, then push the reviewed commits. The push must trigger the workflow.

- [ ] **Step 3: Monitor every workflow step**

Expected successful steps:

```text
Install dependencies
Build application
Configure AWS credentials
Login to Amazon ECR
Build Docker image
Push Docker image
Deploy ECS Express service
```

Do not call the migration complete if the deploy step is skipped, pending, or failed.

- [ ] **Step 4: Verify the public endpoint**

```powershell
$endpoint = Read-Host 'HTTPS endpoint shown in ecs_express_ingress_paths'
Invoke-WebRequest -UseBasicParsing $endpoint
```

Expected: HTTP `200` and the current NestJS response body.

- [ ] **Step 5: Prove rollback with the previous known-good SHA**

Use the exact rollback command from `docs/runbooks/ecs-express-operations.md`, monitor until active, verify HTTP `200`, then redeploy the newest SHA and verify HTTP `200` again.

- [ ] **Step 6: Final repository and remote verification**

```powershell
git status --short --branch
git rev-parse HEAD
git ls-remote --heads origin main
```

Expected: working tree is clean and local `HEAD`, `origin/main`, and the remote `main` hash match.
