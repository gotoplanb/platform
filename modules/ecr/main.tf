# Shared ECR repo (platform#20, ADR-017). ONE repo for the estate so build-once /
# promote-by-digest works: the image is built+scanned once and the SAME digest is deployed
# to staging then prod. (Replaces the per-env repos that #6 created — those can't promote a
# single artifact across envs.)

variable "name" {
  description = "Repo name (e.g. watch)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "pull_account_ids" {
  description = "Extra AWS account ids allowed to pull (cross-account promote-by-digest, ADR-020/#22). Empty = same-account only, so this is gated with the split."
  type        = list(string)
  default     = []
}

resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE" # promote by digest; tags never move
  force_delete         = true        # ephemeral test loop (ADR-015)

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# Cross-account pull: the prod account (watch-prod) pulls the SAME digest built once in nonprod
# (ADR-017 across the account boundary). GetAuthorizationToken is account-level (the puller's
# ECS execution role already has it via AmazonECSTaskExecutionRolePolicy); the repo policy grants
# the layer/image reads cross-account.
resource "aws_ecr_repository_policy" "cross_account_pull" {
  count      = length(var.pull_account_ids) > 0 ? 1 : 0
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CrossAccountPull"
      Effect    = "Allow"
      Principal = { AWS = [for id in var.pull_account_ids : "arn:aws:iam::${id}:root"] }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
    }]
  })
}

output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.this.arn
}

output "repository_name" {
  value = aws_ecr_repository.this.name
}
