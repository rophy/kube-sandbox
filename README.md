# kube-sandbox

Disposable Kubernetes cluster on AWS with minimal cost using K3s and Terraform.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         VPC (10.0.0.0/16)                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              Public Subnet (10.0.1.0/24)              │  │
│  │                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │  │
│  │  │   Node 1    │  │   Node 2    │  │   Node 3    │   │  │
│  │  │ m6i.2xlarge │  │ m6i.2xlarge │  │ m6i.2xlarge │   │  │
│  │  │             │  │             │  │             │   │  │
│  │  │ K3s Server  │  │ K3s Agent   │  │ K3s Agent   │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘   │  │
│  │     workload=db    workload=stream  workload=client  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker and Docker Compose
- AWS credentials (via `~/.aws` or environment variables)
- S3 bucket for Terraform state (see below)

## AWS Setup

### S3 Backend

Terraform uses an S3 bucket to store state with native state locking. Before running `make init`, update `terraform/versions.tf` with your bucket:

```hcl
backend "s3" {
  bucket       = "your-bucket-name"    # Change this
  key          = "kube-sandbox/terraform.tfstate"
  region       = "us-east-1"           # Change to your region
  encrypt      = true
  use_lockfile = true
}
```

Create the bucket if it doesn't exist:

```bash
aws s3 mb s3://your-bucket-name --region us-east-1
```

### Required IAM Permissions

Your AWS credentials need the following permissions:

| Service | Permissions | Purpose |
|---------|-------------|---------|
| EC2 | Full access | Instances, AMIs, volumes, security groups, key pairs |
| VPC | Full access | VPCs, subnets, internet gateways, route tables |
| IAM | Limited | Create roles, instance profiles, policies |
| S3 | Read/Write | Terraform state bucket access |

Example IAM policy (attach to your user or role):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:TagRole",
        "iam:TagInstanceProfile"
      ],
      "Resource": "*"
    }
  ]
}
```

For simpler setup, you can use AWS managed policies:
- `AmazonEC2FullAccess`
- `AmazonVPCFullAccess`
- `IAMFullAccess` (or the limited policy above)
- S3 access to your state bucket

## Quick Start

### 1. Enter Dev Container

```bash
make shell
```

### 2. Create Cluster

```bash
make init    # First time only - initializes Terraform
make up      # Creates cluster and fetches kubeconfig
```

### 3. Verify Cluster

```bash
kubectl get nodes -o wide
```

### 4. Destroy When Done

```bash
make down
```

This destroys all AWS resources and cleans up any orphaned EBS volumes created by the CSI driver.

## Make Targets

| Command | Description |
|---------|-------------|
| `make shell` | Start dev container and open shell |
| `make init` | Initialize Terraform (first time only) |
| `make up` | Create K3s cluster and fetch kubeconfig |
| `make down` | Destroy cluster and clean up EBS volumes |
| `make kubeconfig` | Fetch kubeconfig from existing cluster |
| `make help` | Show all available targets |

## Cost

Uses on-demand instances by default. Spot instances can be enabled via `use_spot_instances = true` in terraform.tfvars.

| Node | Instance Type | vCPU | Memory | Role |
|------|---------------|------|--------|------|
| Node 1 | m6i.2xlarge | 8 | 32 GiB | K3s Server |
| Node 2 | m6i.2xlarge | 8 | 32 GiB | K3s Agent |
| Node 3 | m6i.2xlarge | 8 | 32 GiB | K3s Agent |

## Node Labels and Taints

Each node has a label and taint for workload isolation:

| Node | Label | Taint |
|------|-------|-------|
| Node 1 | `workload=db` | `workload=db:NoSchedule` |
| Node 2 | `workload=stream` | `workload=stream:NoSchedule` |
| Node 3 | `workload=client` | `workload=client:NoSchedule` |

To schedule pods on specific nodes:

```yaml
spec:
  nodeSelector:
    workload: db
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "db"
      effect: "NoSchedule"
```

## EBS CSI Driver

The cluster includes the AWS EBS CSI driver for dynamic volume provisioning, automatically deployed on startup.

### Storage Classes

| Name | Description |
|------|-------------|
| `ebs-gp3` (default) | Standard gp3 volumes |
| `ebs-gp3-fast` | gp3 with 4000 IOPS, 250 MB/s throughput |

## Dev Container

The dev container includes:
- Terraform
- AWS CLI
- kubectl
- Claude CLI

KUBECONFIG is automatically configured inside the container.

## Files Structure

```
.
├── CLAUDE.md            # Claude AI instructions
├── Dockerfile           # Dev container
├── docker-compose.yaml
├── Makefile
├── terraform/
│   ├── variables.tf     # Configurable variables
│   ├── vpc.tf           # VPC, subnet, IGW
│   ├── security.tf      # Security groups
│   ├── ec2.tf           # EC2 instances with K3s
│   └── outputs.tf       # Output values
└── scripts/
    └── fetch-kubeconfig.sh
```
