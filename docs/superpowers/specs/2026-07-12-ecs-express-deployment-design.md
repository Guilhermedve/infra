# ECS Express Deployment Design

## Goal

Replace the abandoned App Runner attempt with a cost-conscious Amazon ECS Express Mode deployment for the existing NestJS container. Every push to `main` must build an immutable image, publish it to Amazon ECR, update the ECS Express service, and fail visibly if the rollout does not become healthy.

## Current Context

- The NestJS application lives in `project-name/` and listens on port `3000`.
- GitHub Actions already authenticates to AWS through GitHub OIDC and pushes images to the private ECR repository `rocketseat-ci` in `us-east-2`.
- The OIDC trust is restricted to the immutable GitHub subject for `Guilhermedve/infra` on `main`.
- The repository pins AWS Provider `5.49.0`, which predates `aws_ecs_express_gateway_service`.
- `iac/iam.tf` contains an uncommitted, syntactically invalid App Runner role attempt. The migration replaces that block without changing the working GitHub OIDC trust.
- The AWS account has approximately USD 100 in promotional credits. Credits are temporary; the deployment must remain inexpensive and observable.

## Chosen Architecture

Use ECS Express Mode with a directly configured `primary_container`, not a custom ECS task definition. Express Mode provisions and manages the Fargate service, Application Load Balancer, HTTPS endpoint, networking, auto scaling, logs, and deployments while keeping the resources visible in the account.

The service runs one Linux task at `0.25 vCPU` and `0.5 GB` memory, with a scaling range of one to two tasks. The primary container uses the existing private ECR image, exposes TCP port `3000`, and uses `/` as its initial health check because the current NestJS application already serves that route.

The Terraform AWS Provider is upgraded to `6.33.0`. This version is selected explicitly because it includes `aws_ecs_express_gateway_service`; the upgrade is validated before any infrastructure is applied.

## Components and Responsibilities

### ECR

The existing `aws_ecr_repository.test` resource remains the image registry. Its Terraform local name is not changed during this migration to avoid an unnecessary resource replacement. GitHub Actions tags every image with `${{ github.sha }}`; deployments never depend on mutable `latest` tags.

### IAM

The invalid App Runner role is removed and replaced with two roles required by ECS Express:

1. `ecsTaskExecutionRole` trusts `ecs-tasks.amazonaws.com` and attaches `arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy`. ECS uses it to pull the private ECR image and deliver container logs.
2. `ecsInfrastructureRoleForExpressServices` trusts `ecs.amazonaws.com` and attaches `arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices`. ECS Express uses it to manage the load balancer, networking, scaling, and related infrastructure.

The existing `github-actions-ecr-role` remains responsible for GitHub OIDC. Its inline permissions are extended only with the minimum ECS Express actions needed to describe and update this specific service after the service ARN exists. Initial service creation remains a Terraform operation performed deliberately from an authenticated operator session.

### ECS Express Service

Terraform creates one public `aws_ecs_express_gateway_service` in `us-east-2` with:

- service name `infra-project-name`;
- container image from `rocketseat-ci`;
- container port `3000`;
- health check path `/`;
- CPU `256` and memory `512`;
- minimum task count `1` and maximum task count `2`;
- AWS-managed public HTTPS endpoint;
- default VPC networking initially, after a preflight confirms the account has a default VPC and at least two usable subnets.

The initial Terraform apply uses an image tag that already exists in ECR. Terraform outputs the service ARN and application URL.

### GitHub Actions Deployment

The workflow retains checkout, dependency installation, NestJS build, AWS OIDC authentication, ECR login, Docker build, and Docker push. After pushing `${{ github.sha }}`, it updates the ECS Express service to the same immutable image URI and monitors the deployment until it reaches `ACTIVE` or fails.

Pull requests run install and build only. AWS authentication, image publishing, and deployment remain restricted to pushes on `main`.

The workflow grants no static AWS keys and does not store the account role ARN in a secret because the verified role ARN is not confidential and is already scoped by its OIDC trust policy.

## Deployment Flow

1. A commit reaches `main`.
2. GitHub Actions installs dependencies and compiles the NestJS application.
3. GitHub obtains short-lived AWS credentials through OIDC.
4. The workflow builds the Docker image from the repository root.
5. The image is pushed to ECR as `<registry>/rocketseat-ci:<commit-sha>`.
6. The workflow updates `infra-project-name` to that exact image URI.
7. ECS Express performs the managed rollout and health checks `/` on port `3000`.
8. The workflow monitors the service and succeeds only after the deployment becomes active.

## Failure Handling and Rollback

- Terraform validation or provider-upgrade errors stop before `terraform apply`.
- A missing default VPC or fewer than two usable subnets blocks initial creation with a clear preflight failure.
- Build, ECR push, ECS update, or rollout failures fail the GitHub Actions job.
- Every image remains addressable by commit SHA. Rollback updates the service to the last known-good SHA and monitors the rollback deployment.
- ECR lifecycle rules retain the most recent 20 tagged images and remove untagged images after seven days, limiting storage growth without deleting immediate rollback candidates.
- Terraform state remains local for this phase and continues to be ignored by Git. Remote state is a separate future improvement and is not introduced in this migration.

## Cost Controls

- Keep one task minimum and two tasks maximum.
- Use `0.25 vCPU / 0.5 GB` per task.
- Retain application logs for seven days.
- Create an AWS Budget for monthly actual and forecasted spend with notification thresholds at USD 10, USD 25, and USD 50.
- Document the destroy sequence for the ECS Express service so the load balancer and Fargate tasks can be removed before promotional credits expire.
- Treat the approximately USD 100 credit as temporary. Expected low-traffic cost after credits is approximately USD 25–30 per month, dominated by the load balancer and continuously running Fargate task.

Budget notifications require one operator email address supplied at implementation time through a sensitive Terraform variable or local `.tfvars` file that is ignored by Git. No email address is committed to the repository.

## Files and Boundaries

- `iac/main.tf`: raise the AWS Provider constraint to `6.33.0`.
- `iac/iam.tf`: remove the App Runner attempt; define ECS task-execution and infrastructure roles plus policy attachments; preserve GitHub OIDC.
- `iac/ecs-express.tf`: define the ECS Express service and its image/scaling/health configuration.
- `iac/ecr.tf`: add lifecycle retention without replacing the repository.
- `iac/budget.tf`: define the monthly cost budget and notification thresholds.
- `iac/variables.tf`: declare the budget notification email and initial image tag inputs.
- `iac/outputs.tf`: expose the ECS Express service ARN and application URL.
- `.github/workflows/main.yml`: add immutable ECS Express deployment and monitoring after ECR push.
- `.gitignore`: ignore Terraform variable files containing the budget email.
- `docs/runbooks/ecs-express-operations.md`: document initial apply, normal deploy, rollback, cost monitoring, and destroy procedures.

## Validation Strategy

Before infrastructure changes:

- `terraform init -upgrade` resolves AWS Provider `6.33.0`.
- `terraform fmt -check -recursive` passes.
- `terraform validate` passes.
- `terraform plan` shows App Runner role removal only if it was ever applied; otherwise it shows only ECS Express additions and intended IAM changes.
- AWS CLI preflight confirms an existing ECR image, default VPC, and at least two subnets in `us-east-2`.

Application and delivery checks:

- `npm --prefix project-name run build` passes.
- `npm --prefix project-name test -- --runInBand` passes.
- `docker build -t infra-project-name:verify -f project-name/Dockerfile .` passes when Docker Desktop is available.
- The workflow YAML passes Prettier parsing.
- The first deployment reaches `ACTIVE`.
- An HTTPS request to the Terraform output URL returns a successful response from the NestJS application.
- A controlled redeploy to a previous commit SHA proves rollback before the migration is considered complete.

## Out of Scope

- Custom domain and Route 53 records.
- Private VPC design or NAT gateways.
- A custom ECS task definition.
- Database, cache, or application secrets.
- Multi-region deployment.
- Remote Terraform state migration.
- Production SLOs beyond the managed health check and basic budget alarms.

## Success Criteria

- No App Runner resource or role remains in the desired Terraform configuration.
- Terraform manages a valid ECS Express service in `us-east-2`.
- Pushes to `main` deploy the exact commit-tagged image automatically.
- Pull requests cannot authenticate to AWS or deploy.
- The service responds over its AWS-managed HTTPS URL.
- Rollback to a previous image SHA is documented and tested.
- Monthly budget alerts exist at USD 10, USD 25, and USD 50.
- The repository contains no Terraform state, credentials, static AWS keys, or committed notification email.
