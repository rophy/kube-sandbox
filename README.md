# kube-sandbox

Disposable Kubernetes cluster on AWS for testing and experimentation. Uses K3s for lightweight Kubernetes and includes automatic idle detection to prevent runaway costs.

## Features

- **4-node K3s cluster** (1 master + 3 workers)
- **Auto-destroy** - cluster automatically destroys itself after 30 minutes of inactivity
- **Elastic IPs** - stable public IPs survive instance replacements
- **EBS CSI driver** - dynamic volume provisioning with gp3 storage
- **mTLS API access** - secure external kubectl access via nginx proxy
- **Status API** - check cluster status and predicted shutdown time

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                    AWS                                        │
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ Control Plane (always on, ~$0/month)                                   │  │
│  │                                                                        │  │
│  │  EventBridge ──(5min)──► Check Lambda ──(idle)──► Destroy Lambda       │  │
│  │                              │                                         │  │
│  │                              ▼                                         │  │
│  │                      CloudWatch Metrics                                │  │
│  │                                                                        │  │
│  │  API Gateway ──► Status Lambda (returns cluster status JSON)           │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                 ▲                                             │
│                                 │ publishes metrics                           │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ Data Plane (on-demand, pay per use)                                    │  │
│  │                                                                        │  │
│  │  ┌────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐                 │  │
│  │  │ master │   │ worker1 │   │ worker2 │   │ worker3 │                 │  │
│  │  │(server)│   │ (agent) │   │ (agent) │   │ (agent) │                 │  │
│  │  └────────┘   └─────────┘   └─────────┘   └─────────┘                 │  │
│  │                                                                        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Auto-Destroy

The cluster monitors K8s API activity and automatically destroys itself when idle:

1. **EC2 cronjob** publishes API request count to CloudWatch every 5 minutes
2. **Check Lambda** (EventBridge scheduled) checks metrics every 5 minutes
3. If no API activity for 30 minutes → **Destroy Lambda** runs `terraform destroy`

This ensures you won't forget to destroy the cluster and accumulate unexpected charges.

**Safety features:**
- Missing metrics (EC2 stuck) is treated as idle → still gets destroyed
- Errors checking metrics → safe default, no destroy
- `enable_auto_destroy = false` disables destruction (dry-run mode)

**Status API:**
After deploying the infra, a status API endpoint is available:
```bash
# Get API URL from terraform output
cd terraform/infra && terraform output status_api_url

# Example response
curl https://xxxxxxx.execute-api.ap-east-2.amazonaws.com/prod/status
{
  "status": "active",
  "last_activity_at": "2026-01-18T16:01:30Z",
  "idle_since_minutes": 2.9,
  "destroy_at": "2026-01-18T16:31:30Z"
}
```

## Prerequisites

- Docker and Docker Compose
- AWS credentials with EC2, VPC, IAM, Lambda, CloudWatch, S3 permissions
- S3 bucket for Terraform state
- ECR repository for Lambda image

## Quick Start

### 1. One-time Setup

```bash
# Create S3 bucket for Terraform state
aws s3 mb s3://kube-sandbox-YOUR_ACCOUNT_ID --region ap-east-2

# Create ECR repository for Lambda image
aws ecr create-repository --repository-name kube-sandbox-tf --region ap-east-2

# Configure backend
cp terraform/backend.tfvars.example terraform/backend.tfvars
# Edit with your bucket name
```

### 2. Build and Push Lambda Image

```bash
# Set variables
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=ap-east-2
ECR=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR

# Build and push Terraform image (apply/destroy Lambdas - same image, different TF_ACTION env var)
docker build -f Dockerfile.tf -t $ECR/kube-sandbox-tf:latest .
docker push $ECR/kube-sandbox-tf:latest
```

Note: The check/status Lambda uses Node.js (no Docker image needed - AWS SDK v3 is built-in).

### 3. Configure Terraform

Create `terraform/infra/terraform.tfvars`:
```hcl
lambda_tf_image_uri = "YOUR_ACCOUNT_ID.dkr.ecr.ap-east-2.amazonaws.com/kube-sandbox-tf:latest"
github_repo_url     = "https://github.com/YOUR_USER/kube-sandbox.git"
tf_state_bucket     = "kube-sandbox-YOUR_ACCOUNT_ID"
enable_auto_destroy = true
```

Create `terraform/cluster/terraform.tfvars` (optional, to override defaults):
```hcl
master_instance_type  = "t3.small"
worker1_instance_type = "t3.large"
worker2_instance_type = "t3.large"
worker3_instance_type = "t3.large"
```

### 4. Deploy

```bash
# Enter dev container
make shell

# Initialize Terraform (first time only)
make init

# Deploy control plane (Lambda functions)
cd terraform/infra && terraform apply

# Create cluster
make up
```

### 5. Use the Cluster

```bash
kubectl get nodes
```

### 6. Destroy (or let auto-destroy handle it)

```bash
make down
```

## Make Targets

| Command | Description |
|---------|-------------|
| `make shell` | Enter dev container |
| `make init` | Initialize Terraform |
| `make build` | Build Lambda image (kube-sandbox-tf) |
| `make up` | Create cluster and fetch kubeconfig |
| `make down` | Destroy cluster and clean up EBS volumes |
| `make kubeconfig` | Fetch kubeconfig from existing cluster |

## Node Configuration

| Node | Role | Instance Type | Label |
|------|------|---------------|-------|
| master | K3s server | t3.small | `role=master` |
| worker1 | K3s agent | t3.large | `role=worker1` |
| worker2 | K3s agent | t3.large | `role=worker2` |
| worker3 | K3s agent | t3.large | `role=worker3` |

## Storage Classes

| Name | Description |
|------|-------------|
| `ebs-gp3` (default) | Standard gp3 volumes |
| `ebs-gp3-fast` | gp3 with 4000 IOPS, 250 MB/s |

## Cost Optimization

- Control plane (Lambda + EventBridge) costs ~$0/month when idle
- Cluster costs only when running (EC2 on-demand or spot)
- Auto-destroy prevents forgotten clusters from accumulating charges
- Use `use_spot_instances = true` for additional savings
