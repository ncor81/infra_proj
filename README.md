# infra_proj

A containerized Python REST API deployed to AWS ECS Fargate, provisioned entirely with Terraform, and shipped through a GitHub Actions CI/CD pipeline. Infrastructure is designed to be spun up and torn down on demand, keeping running costs within the AWS Free Tier.

**Stack:** Python 3.12 · FastAPI · Docker · Terraform 1.10 · AWS ECR + ECS Fargate · GitHub Actions · WSL2 (Ubuntu)

---

## What this project does

A FastAPI application exposes two HTTP endpoints:

| Endpoint | Response |
|----------|----------|
| `GET /` | `{"status": "ok"}` |
| `GET /health` | `{"healthy": true}` |

The application is containerized, pushed to AWS ECR, and deployed as a Fargate task in a VPC with public subnets. Every push to `main` triggers a three-job GitHub Actions pipeline: run tests, build and push a new Docker image tagged with the git SHA, then update the ECS service to the new image. A separate manually-triggered workflow tears down all AWS infrastructure with a single click.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for a full breakdown of design decisions, cost analysis, and the production hardening roadmap.

---

## Prerequisites

- Windows 10/11 with WSL2 running Ubuntu 22.04 or 24.04
- [Docker Engine](https://docs.docker.com/engine/install/ubuntu/) installed inside WSL2 (not Docker Desktop)
- [Terraform](https://github.com/tfutils/tfenv) >= 1.10 via `tfenv`
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed inside WSL2
- An AWS account with an IAM user that has programmatic access
- A GitHub account

> All commands below run inside your WSL2 terminal unless marked **[Windows]**.

---

## Clone and run locally

```bash
# Clone the repository
git clone git@github.com:<you>/infra_proj.git
cd infra_proj

# Build the image
docker build -t infra_proj:local ./app

# Run locally
docker run -p 8000:8000 infra_proj:local

# Test the endpoints (separate terminal tab)
curl http://localhost:8000/
curl http://localhost:8000/health
```

WSL2 forwards ports automatically — both endpoints are also reachable at `http://localhost:8000` in your Windows browser.

---

## Deploy to AWS

### 1. Configure AWS credentials

```bash
aws configure --profile iam-dev
# Enter your Access Key ID, Secret Access Key, region (us-east-1), output format (json)

# Persist the profile so Terraform picks it up automatically
echo 'export AWS_PROFILE=iam-dev' >> ~/.bashrc
source ~/.bashrc

# Verify
aws sts get-caller-identity --profile iam-dev
```

### 2. Create the Terraform remote state bucket

```bash
aws s3api create-bucket \
  --bucket myapp-tf-state-<your-account-id> \
  --region us-east-1 \
  --profile iam-dev

aws s3api put-bucket-versioning \
  --bucket myapp-tf-state-<your-account-id> \
  --versioning-configuration Status=Enabled \
  --profile iam-dev
```

Update `infra/backend.tf` with your bucket name before proceeding.

### 3. Provision infrastructure

```bash
cd infra
terraform init
terraform plan -var="app_name=infra_proj" -var="aws_region=us-east-1" -out=tfplan
terraform apply tfplan

# Note the ECR URL from the output
terraform output ecr_repository_url
```

### 4. Add GitHub Secrets

In your GitHub repo → Settings → Secrets and variables → Actions, add:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `AWS_ACCOUNT_ID` | 12-digit AWS account ID (used to construct the ECR registry URL) |
| `AWS_REGION` | `us-east-1` |
| `ECR_REPOSITORY` | `infra_proj` — the repo name only, not the full URL |
| `ECS_CLUSTER_NAME` | `infra_proj-cluster` |
| `ECS_SERVICE_NAME` | `infra_proj` |

### 5. Deploy

Push any commit to `main` to trigger the deploy pipeline:

```bash
git add .
git commit -m "deploy"
git push origin main
```

Monitor the run under GitHub → Actions → Build and deploy.

### 6. Verify the deployment

```bash
# Check the service is running
aws ecs describe-services \
  --cluster infra_proj-cluster \
  --services infra_proj \
  --profile iam-dev \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount}' \
  --output table

# Get the task's public IP
TASK_ARN=$(aws ecs list-tasks \
  --cluster infra_proj-cluster \
  --service-name infra_proj \
  --profile iam-dev \
  --query 'taskArns[0]' --output text)

ENI_ID=$(aws ecs describe-tasks \
  --cluster infra_proj-cluster \
  --tasks $TASK_ARN \
  --profile iam-dev \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text)

PUBLIC_IP=$(aws ec2 describe-network-interfaces \
  --network-interface-ids $ENI_ID \
  --profile iam-dev \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text)

curl http://$PUBLIC_IP:8000/health
# Expected: {"healthy":true}
```

---

## Tear down infrastructure

To avoid charges, destroy all AWS resources at the end of each session. Go to GitHub → Actions → **Destroy infrastructure** → Run workflow.

To bring everything back up: run `terraform apply` from `infra/`, then push a commit to redeploy the app.

---

## Project structure

```
infra_proj/
├── app/
│   ├── main.py                  # FastAPI application
│   ├── requirements.txt         # Python dependencies
│   └── Dockerfile               # Multi-stage, non-root image
├── infra/
│   ├── backend.tf               # S3 remote state + native locking
│   ├── main.tf                  # VPC, ECR, ECS, IAM
│   ├── variables.tf
│   ├── outputs.tf
│   └── task-definition.json     # ECS task definition base for CI/CD
└── .github/
    └── workflows/
        ├── deploy.yml           # Push to main → test → build → deploy
        └── destroy.yml          # Manual trigger → terraform destroy
```

---

## Troubleshooting

**`No valid credential sources found`** — Run `export AWS_PROFILE=iam-dev` or open a new terminal to reload `~/.bashrc`.

**`git push` fails after WSL restart** — The SSH agent doesn't persist across sessions. Re-add the key:
```bash
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
```

**ECS task not starting (`runningCount: 0`)** — Check the stopped reason:
```bash
aws ecs list-tasks \
  --cluster infra_proj-cluster \
  --desired-status STOPPED \
  --profile iam-dev \
  --query 'taskArns[0]' --output text \
| xargs -I {} aws ecs describe-tasks \
  --cluster infra_proj-cluster \
  --tasks {} \
  --profile iam-dev \
  --query 'tasks[0].stoppedReason'
```

**`CannotPullContainerError`** — Confirm `infra/task-definition.json` uses the full ECR image URI including the registry prefix (`<account-id>.dkr.ecr.us-east-1.amazonaws.com/infra_proj:latest`), and that the `latest` tag was pushed by the build step.

**Terraform destroy fails on ECR** — `force_delete = true` is set in `main.tf` to allow destroy even when images are present. If you have manually overridden this, the ECR repo must be emptied first.