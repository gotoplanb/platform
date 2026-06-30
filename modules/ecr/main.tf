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

output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.this.arn
}

output "repository_name" {
  value = aws_ecr_repository.this.name
}
