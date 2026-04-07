# Architecture

This document covers the design decisions behind `infra_proj`, the cost model for the current dev environment, and a prioritized roadmap of production hardening changes. It is written for engineers evaluating the project and as a reference for future work.

---

## System overview

```
Developer (WSL2)
      │
      │  git push → main
      ▼
GitHub Actions
  ├── test job         (pytest)
  ├── build-and-push   (docker build → ECR)
  └── deploy job       (render task definition → ECS service update)
                                │
                    ┌───────────▼────────────┐
                    │      AWS us-east-1      │
                    │                         │
                    │  ┌─────────────────┐   │
                    │  │   ECR Registry  │   │
                    │  └────────┬────────┘   │
                    │           │ pull        │
                    │  ┌────────▼────────┐   │
                    │  │  ECS Fargate    │   │
                    │  │  (1 task)       │   │
                    │  │  port 8000      │   │
                    │  └────────┬────────┘   │
                    │           │             │
                    │  ┌────────▼────────┐   │
                    │  │   VPC           │   │
                    │  │   Public subnet │   │
                    │  │   Public IP     │   │
                    │  └─────────────────┘   │
                    └─────────────────────────┘

Terraform state → S3 (versioned, native locking)
```

Traffic flows directly from the internet to the ECS task's assigned public IP on port 8000. There is no load balancer or NAT gateway in this environment — a deliberate cost decision explained below.

---

## Infrastructure decisions

### Compute: ECS Fargate over EC2

Fargate was chosen over EC2 for two reasons. First, there is no instance to manage, patch, or right-size — the task definition specifies CPU and memory and AWS handles placement. Second, Fargate scales to zero when the service's desired count is set to 0, which matters for a dev environment where infrastructure is destroyed nightly.

The tradeoff is cost per vCPU-hour. At production scale, EC2 with reserved instances is significantly cheaper than Fargate on-demand pricing. For a portfolio project with intermittent uptime, Fargate's operational simplicity outweighs its unit cost.

**Production change:** At sustained load, migrate to EC2 Spot instances with an Auto Scaling group managed by ECS Capacity Providers. This can cut compute cost by 60–70% vs Fargate on-demand while maintaining the same deployment model.

---

### Networking: public subnets with no NAT gateway

ECS tasks run in public subnets with `assign_public_ip = true`. This means each task gets a public IP directly, which allows it to pull images from ECR and reach the internet without a NAT gateway.

**Why no NAT gateway:** A NAT gateway costs ~$32/month plus $0.045/GB data processed. For a dev environment destroyed nightly, this is the single largest avoidable cost item. Eliminating it keeps the project within Free Tier.

**The security tradeoff:** Tasks in public subnets are directly reachable from the internet (constrained only by the security group). In a real deployment, application workloads belong in private subnets, reachable only through a load balancer. The current security group restricts inbound to port 8000 only, which limits the exposure surface, but the pattern is not production-appropriate.

**Production change:** Move ECS tasks to private subnets. Add a NAT gateway (or VPC endpoints for ECR/S3) for outbound traffic. Place an Application Load Balancer in the public subnets to terminate HTTPS and forward to the private tasks. This is the standard three-tier VPC pattern and the correct target architecture.

---

### Load balancing: none in this environment

There is no ALB in front of the ECS service. The API is reached directly via the task's public IP, which changes every time the task is replaced (deployments, restarts, or nightly destroy/recreate cycles).

**Why omitted:** An ALB costs ~$16/month minimum regardless of traffic. For a portfolio environment that is destroyed nightly, this cost is not justified. The technical capability to deploy one is demonstrated through the VPC and subnet configuration, which is already structured to support an ALB (two public subnets across two AZs).

**Production change:** Add an `aws_lb`, `aws_lb_listener`, and `aws_lb_target_group` in Terraform. Point the ECS service's `load_balancer` block at the target group. The ALB provides a stable DNS name, health-check-based routing across multiple tasks, and TLS termination via ACM certificates. This is the first hardening step for any real workload.

---

### State management: S3 with native locking, no DynamoDB

Terraform state is stored in S3 with versioning enabled. State locking uses Terraform 1.10's native S3 locking (`use_lockfile = true`), which writes a `.tflock` file to the same bucket rather than requiring a separate DynamoDB table.

**Why no DynamoDB:** DynamoDB has a free tier (25 GB storage, 25 read/write capacity units), so the cost difference is minimal. The real benefit of eliminating it is reduced infrastructure surface — one fewer resource to provision, manage, and grant IAM permissions to. For a single-operator project there is negligible concurrent-access risk.

**Production change:** In a team environment with multiple engineers or automated pipelines running plans simultaneously, DynamoDB locking provides stronger guarantees because it uses conditional writes with a TTL on the lock record. If concurrent Terraform runs are a real risk, add the DynamoDB table back. The `use_lockfile` approach is sufficient for single-operator or sequential pipeline workflows.

---

### ECR: mutable tags with `force_delete = true`

**Mutable image tags (`image_tag_mutability = "MUTABLE"`)** means an existing tag (such as `latest`) can be overwritten by a new image push. The deploy workflow already tags every image with the unique git SHA, so tag collisions never occur in practice. Mutable is the simpler default because it never causes a push to fail.

In production, `IMMUTABLE` is the correct setting. Immutability gives a cryptographic guarantee: if a container is running image tag `a3f92c1`, that tag will always refer to exactly the same image layers. It prevents accidental or malicious overwrites of a known-good image, which is important for security audits, incident response, and compliance requirements.

**Production change:** Set `image_tag_mutability = "IMMUTABLE"` and ensure the deploy workflow never attempts to re-push an existing SHA tag. The `latest` convenience tag would need to be handled separately (e.g., via a manifest list or dropped in favour of SHA-only deploys).

---

**`force_delete = true`** allows Terraform to delete the ECR repository even when it contains images. Without this flag, `terraform destroy` would fail on any ECR repo that has images, leaving infrastructure in a partially torn-down state. Since the destroy workflow runs nightly and the repo will always have images from the deploy workflow, `force_delete = true` is required for reliable automated teardown.

In production, set this to `false` or omit it entirely. Accidentally deleting a production image registry is a serious incident — the AWS default protection exists for good reason. Nightly teardown is a dev-environment pattern only.

---

### Deployment: circuit breaker with fast pipeline

The ECS service has a deployment circuit breaker enabled with `rollback = true`. If a new task revision fails to reach a healthy state, ECS automatically rolls the service back to the last stable revision without operator intervention.

The GitHub Actions deploy workflow uses `wait-for-service-stability: false`, which means the pipeline reports success as soon as the new task definition is registered and the service update is initiated — not after ECS confirms the new task is healthy. This keeps pipeline run time short (typically under 2 minutes for the deploy job).

The combination works well: the pipeline is fast, and ECS handles recovery autonomously via the circuit breaker. The risk is that a failed deployment is not immediately visible in the GitHub Actions UI — you need to check ECS service events or CloudWatch Logs to confirm the rollback occurred.

**Production change:** Add a post-deploy smoke test job that polls the ALB health check endpoint for 60–120 seconds after the deploy job completes. This closes the visibility gap without blocking the pipeline on ECS's full stabilization timeout (up to 10 minutes for large deployments).

---

### CI/CD: two image tags per build

Every build pushes two tags to ECR: the git SHA (e.g., `a3f92c1`) and `latest`. Both serve different purposes:

- The **SHA tag** is what the deploy step registers in the ECS task definition. It is immutable in practice (every commit produces a unique SHA), provides an exact audit trail of what is running, and enables rollback by re-deploying a previous SHA.
- The **`latest` tag** is what the task definition's image field references as a fallback. ECS uses it when a task restarts after a destroy/recreate cycle or a manual scale event. Without `latest`, a restarted task pulls no image and fails with `CannotPullContainerError`.

**Production change:** In a fully immutable-tag environment, drop the `latest` tag and always deploy by SHA. Pair this with an image promotion workflow: CI builds and tags `sha-<commit>`, a separate promotion step retags it as `env-prod-<commit>` after passing integration tests, and ECS deployments always use the promoted tag. This pattern is standard in regulated environments.

---

### IAM: task execution role, no task role

The current configuration creates an ECS task **execution role** — the role ECS assumes to pull images from ECR and write logs to CloudWatch on the container's behalf. There is no **task role** configured.

A task role is what the application code itself would use to call AWS APIs (e.g., reading from S3, writing to DynamoDB, publishing to SQS). Since the current application makes no AWS API calls, no task role is needed.

**Production change:** If the application needs to access AWS services, create a dedicated `aws_iam_role` for the task role with least-privilege permissions scoped to only the resources that service needs. Attach it via `task_role_arn` in the task definition. Never use the execution role for application-level AWS access — these are separate trust boundaries.

---

### Secrets management: GitHub Secrets only

AWS credentials (access key ID and secret) are stored as GitHub Actions secrets and injected into the pipeline at runtime. The application itself has no secrets to manage in the current implementation.

**Production change:** Rotate IAM access keys regularly or, preferably, replace long-lived keys with OIDC federation. GitHub Actions supports AWS OIDC — the pipeline assumes an IAM role via a short-lived token rather than storing static credentials. This eliminates the key rotation burden and removes credentials from GitHub entirely. The Terraform change is an `aws_iam_openid_connect_provider` resource and an IAM role with the appropriate trust policy.

For application secrets (database passwords, API keys), use AWS Secrets Manager or Parameter Store. Reference secrets in the ECS task definition via `secrets` in `containerDefinitions` — ECS injects them as environment variables at task start time, and they never appear in version control or task definition JSON.

---

## Cost model

### Current dev environment (nightly destroy)

| Resource | Monthly cost (approx) |
|----------|-----------------------|
| ECS Fargate (0.25 vCPU / 0.5 GB, ~4 hrs/day) | ~$1.50 |
| ECR storage (< 1 GB, 3-image lifecycle policy) | ~$0.10 |
| S3 state bucket (< 1 MB) | < $0.01 |
| VPC / subnets / security groups | $0.00 |
| **Total** | **< $2/month** |

The nightly destroy workflow is the primary cost control mechanism. Fargate tasks are the only resource that incurs cost while running — all other resources (VPC, ECR, S3) are either free or negligible at this scale.

### Production target architecture (estimated)

| Resource | Monthly cost (approx) |
|----------|-----------------------|
| ECS Fargate (2 tasks, 0.5 vCPU / 1 GB, 24/7) | ~$30 |
| Application Load Balancer | ~$16 |
| NAT Gateway (1 AZ) | ~$32 + data transfer |
| ECR storage | ~$1 |
| CloudWatch Logs | ~$2 |
| ACM certificate | $0.00 |
| **Total** | **~$80–100/month** |

Switching ECS to Fargate Spot reduces the compute line by ~70% at the cost of potential task interruptions. For a stateless API behind an ALB with multiple tasks, Spot is appropriate. For a single-task dev environment, the savings are minimal and interruptions are more disruptive.

---

## Production hardening roadmap

The following changes are ordered by impact. Each is a self-contained improvement that can be applied incrementally.

### Priority 1 — Networking and TLS

Add an Application Load Balancer in front of ECS. Move ECS tasks to private subnets. Add a NAT gateway (or VPC endpoints for ECR, S3, and CloudWatch) for outbound traffic. Issue an ACM certificate and terminate HTTPS at the ALB. This is the minimum required for any internet-facing production workload.

### Priority 2 — OIDC authentication for CI/CD

Replace static IAM access keys in GitHub Secrets with OIDC federation. The pipeline assumes a role via short-lived token — no stored credentials, no rotation schedule, reduced blast radius if the repository is compromised.

### Priority 3 — Immutable image tags and image promotion

Switch ECR to `IMMUTABLE` tags. Implement a promotion workflow: build tags `sha-<commit>`, integration tests promote to `env-prod-<commit>`, ECS deploys only promoted tags. Provides a full audit trail of exactly what code ran in production at any point in time.

### Priority 4 — Secrets management

Move any application secrets to AWS Secrets Manager. Reference them in the task definition's `secrets` block. Eliminates secrets from version control, environment variables in the container, and task definition JSON stored in plaintext.

### Priority 5 — Observability

Add CloudWatch Log Groups for ECS task output (structured JSON logging). Add CloudWatch Container Insights for Fargate metrics (CPU, memory, task count). Add a CloudWatch alarm on `CPUUtilization > 80%` and `RunningTaskCount < 1` with SNS notifications. Without observability, production incidents are discovered by users, not operators.

### Priority 6 — Autoscaling

Add an `aws_appautoscaling_target` and `aws_appautoscaling_policy` for the ECS service. Scale on CPU utilization (target 60%) with a minimum of 2 tasks and a maximum based on load expectations. Two tasks as the minimum provides availability during a rolling deployment without requiring a downtime window.

### Priority 7 — Terraform environments and workspaces

Refactor `infra/` to support multiple environments (dev, staging, prod) using either Terraform workspaces or separate state paths. Use a `tfvars` file per environment. This prevents the current pattern where a single `terraform destroy` can take down the only running environment.
