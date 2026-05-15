resource "aws_ecr_repository" "main" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-ecr"
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name

  # One rule per tag prefix so that pushing nginx revisions never evicts the
  # expensive vllm image (10-15 min rebuild because of the baked Gemma weights).
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 vllm images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["vllm"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 nginx images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["nginx"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}