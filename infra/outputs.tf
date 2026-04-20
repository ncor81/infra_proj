output "ecr_repository_url" {
  description = "ECR respository URL for use in CI/CD"
  value       = aws_ecr_repository.app.repository_url
}