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
│  │  │  r6i.large  │  │  c6i.large  │  │  c6i.large  │   │  │
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

## Quick Start

### 1. Start Dev Container

```bash
make shell
```

### 2. Create Infrastructure

```bash
cd terraform
terraform init
terraform apply
```

### 3. Get Kubeconfig

```bash
./scripts/fetch-kubeconfig.sh
export KUBECONFIG=/workspace/kubeconfig.yaml
```

### 4. Verify Cluster

```bash
kubectl get nodes -o wide
```

### 5. Destroy When Done

```bash
cd terraform
terraform destroy
```

## Cost

Uses spot instances by default for cost savings (~70-80% cheaper than on-demand).

| Node | Instance Type | Role |
|------|---------------|------|
| Node 1 | r6i.large | K3s Server |
| Node 2 | c6i.large | K3s Agent |
| Node 3 | c6i.large | K3s Agent |

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

## Dev Container

The dev container includes:
- Terraform
- AWS CLI
- kubectl
- Claude CLI

```bash
make shell    # Enter container
make destroy  # Destroy infrastructure
```

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
