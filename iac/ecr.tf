resource "aws_ecr_repository" "test" {
  name = "rocketseat-ci"

  image_scanning_configuration {
    scan_on_push = true
  }
}