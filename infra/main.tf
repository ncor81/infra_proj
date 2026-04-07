provider "aws" {
    region = var.aws_region
}

module "vpc" {
    source  = "terraform-aws-modules/vpc/aws"
    version = "~> 5.0"
    name    = "${var.app_name}-vpc"
    cidr    = "10.0.0.0/16"
    azs             = ["us-east-1a", "us-east-1b"]
    public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
    enable_nat_gateway  = false
}

resource "aws_ecr_repository" "app" {
    name    = var.app_name
    image_tag_mutability    = "MUTABLE"
    force_delete            = true
    image_scanning_configuration    { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "app" {
    repository  = aws_ecr_repository.app.name
    policy      = jsonencode({ rules = [{rulePriority = 1,
        selection = { tagStatus = "any", countType = "imageCountMoreThan",
        countNumber = 3 }, action = { type = "expire" } }] })
}

resource "aws_ecs_cluster" "main" {
    name = "${var.app_name}-cluster"
}

resource "aws_ecs_service" "app" {
    name            = var.app_name
    cluster         = aws_ecs_cluster.main.id
    task_definition = aws_ecs_task_definition.app.arn 
    desired_count   = 1
    launch_type     = "FARGATE"
    network_configuration {
        subnets             = module.vpc.public_subnets
        security_groups     = [aws_security_group.ecs.id]
        assign_public_ip  = true
    }
    deployment_minimum_healthy_percent  = 0
    deployment_maximum_percent          = 200
    availability_zone_rebalancing       = "DISABLED"

    deployment_circuit_breaker {
        enable      = true
        rollback    = true
    }
}

resource "aws_security_group" "ecs" {
    name        = "${var.app_name}-sg"
    description = "Allow inbound traffic to app"
    vpc_id      = module.vpc.vpc_id

    ingress {
        from_port   = 8000
        to_port     = 8000
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_ecs_task_definition" "app" {
    family                      = var.app_name
    network_mode                = "awsvpc"
    requires_compatibilities   = ["FARGATE"]
    cpu                         = 256
    memory                      = 512
    execution_role_arn          = aws_iam_role.ecs_task_execution.arn

    container_definitions   = jsonencode([{
        name        = var.app_name
        image       = "${aws_ecr_repository.app.repository_url}:latest"
        essential   = true
        portMappings    = [{
            containerPort   = 8000
            protocol        = "tcp"
        }]
        healthCheck = {
            command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
            interval    = 10
            timeout     = 5
            retries     = 3
            startPeriod = 10
        }
    }])
}

resource "aws_iam_role" "ecs_task_execution" {
    name    = "${var.app_name}-ecs-execution-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement   = [{
            Action  = "sts:AssumeRole"
            Effect  = "Allow"
            Principal   = { Service = "ecs-tasks.amazonaws.com"}
        }]
    })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
    role        = aws_iam_role.ecs_task_execution.name
    policy_arn  = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}