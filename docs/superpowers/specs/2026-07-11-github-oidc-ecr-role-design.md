# GitHub OIDC role for ECR

## Goal

Allow only GitHub Actions runs from the `main` branch of `Guilhermedve/infra` to assume an AWS IAM role that can authenticate with and push images to Amazon ECR. Keep the Terraform configuration valid and produce a reviewable plan without applying infrastructure.

## Design

The existing `aws_iam_openid_connect_provider` remains responsible only for registering GitHub's OIDC issuer. A separate `aws_iam_role` owns the web-identity trust policy.

The trust policy requires both claims below with `StringEquals`:

- audience: `sts.amazonaws.com`
- subject: `repo:Guilhermedve/infra:ref:refs/heads/main`

This prevents workflows from other repositories, pull-request refs, tags, and non-main branches from assuming the role.

The role receives an inline ECR policy. `ecr:GetAuthorizationToken` uses `Resource = "*"`, as required by AWS. Repository operations required to push an image are granted separately. Because no ECR repository resource exists in this Terraform configuration, those operations initially use `Resource = "*"`; repository-level restriction can be added when the repository ARN is managed or supplied here.

Terraform exposes the role ARN as an output. The GitHub Actions workflow references `${{ secrets.AWS_ROLE_ARN }}` for `role-to-assume`, because a workflow cannot directly consume a Terraform output before the infrastructure has been applied. After the first apply, the output value must be registered as the repository secret `AWS_ROLE_ARN`.

## Files

- `iac/iam.tf`: OIDC provider, IAM role, trust policy, and ECR permissions.
- `iac/outputs.tf`: role ARN output.
- `.github/workflows/main.yml`: role assumption through the `AWS_ROLE_ARN` secret.

## Verification

Run `terraform fmt -check`, `terraform validate`, and `terraform plan` from `iac`. No `terraform apply` is authorized. Also run `git diff --check` and inspect the final diff to ensure generated `.terraform` content is not included.

## Expected limitation

`terraform plan` requires valid AWS credentials to refresh provider data and may fail locally if credentials are absent or expired. Such an authentication failure is environmental and does not invalidate successful formatting and static validation.
