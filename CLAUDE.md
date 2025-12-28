# Claude Instructions for kube-sandbox

## Environment Check (MANDATORY - DO THIS FIRST)

Check if inside the dev container:

```bash
echo $DEV_CONTAINER
```

If `DEV_CONTAINER` is not `true`, display this warning and STOP:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║   ⚠️  WARNING: YOU ARE NOT INSIDE THE DEV CONTAINER                          ║
║                                                                              ║
║   This project requires running inside the dev container which has           ║
║   Terraform, AWS CLI, and kubectl pre-installed.                             ║
║                                                                              ║
║   Please exit and run Claude from inside the container:                      ║
║                                                                              ║
║       make shell      # Enter the dev container                              ║
║       claude          # Then start Claude inside                             ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

## About This Environment

This is a disposable K3s cluster on AWS with minimal cost. The dev container provides all necessary tools:

- **Terraform** - Infrastructure provisioning
- **AWS CLI** - AWS operations
- **kubectl** - Kubernetes management

Kubeconfig is fetched to `~/.kube/config` (kubectl default path).

## Project Structure

- `terraform/` - Infrastructure as Code for AWS EC2 + K3s
- `scripts/` - Helper scripts (fetch-kubeconfig.sh)

## Common Tasks

### Create Infrastructure
```bash
make init  # First time only
make up    # Creates cluster and fetches kubeconfig
```

### Check Cluster Creation Time
```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=k3s-perf-test-vpc" \
  --query 'Vpcs[0].Tags[?Key==`kube-sandbox/created-at`].Value' --output text
```

This timestamp is set when the VPC is first created and preserved across subsequent `terraform apply` runs.

### Get Kubeconfig (if needed separately)
```bash
make kubeconfig
```

### Destroy Everything
```bash
make down
```

This will:
1. Run `terraform destroy` to remove all AWS resources
2. Clean up any orphaned EBS volumes created by the K8s CSI driver

## EBS CSI Driver

The cluster uses AWS EBS CSI driver for dynamic volume provisioning. This allows PVCs to automatically create EBS volumes.

**The EBS CSI driver is automatically deployed** when the K3s cluster starts (via manifests in `/var/lib/rancher/k3s/server/manifests/`).

### Storage Classes (auto-created)
- `ebs-gp3` (default) - Standard gp3 volumes
- `ebs-gp3-fast` - gp3 with 4000 IOPS, 250 MB/s throughput

## Container Registry (ECR)

The dev container is configured to use AWS ECR as the container registry. This provides a consistent registry endpoint that works from both the dev container and inside K8s pods.

### How It Works

When you run `make build-devcontainer`, the build script:
1. Validates AWS credentials
2. Gets your AWS account ID and region
3. Sets `SKAFFOLD_DEFAULT_REPO` in `.env` (e.g., `572921885201.dkr.ecr.ap-east-2.amazonaws.com`)

The env var is loaded into the container via docker-compose's `env_file` directive.

### Environment Variable

The container has `SKAFFOLD_DEFAULT_REPO` set automatically:
```bash
echo $SKAFFOLD_DEFAULT_REPO
# Output: 572921885201.dkr.ecr.ap-east-2.amazonaws.com
```

### Pushing Images

```bash
# Login to ECR (valid for 12 hours)
aws ecr get-login-password | podman login --username AWS --password-stdin $SKAFFOLD_DEFAULT_REPO

# Push images
podman tag myimage:latest $SKAFFOLD_DEFAULT_REPO/myimage:latest
podman push $SKAFFOLD_DEFAULT_REPO/myimage:latest
```

### Using with Skaffold

Skaffold automatically uses `SKAFFOLD_DEFAULT_REPO` to prefix image names:
```yaml
# skaffold.yaml - images are automatically prefixed with ECR URL
build:
  artifacts:
    - image: myapp  # becomes: 572921885201.dkr.ecr.ap-east-2.amazonaws.com/myapp
```

### K8s Node Access

K8s nodes have IAM instance profiles with ECR pull permissions, so pods can pull images without additional configuration.

## Important Notes

- All AWS operations require valid credentials (mounted from `~/.aws` or via environment variables)
- On-demand instances are used by default
- The cluster is ephemeral - destroy when done to avoid charges
- EBS volumes created by CSI driver are automatically cleaned up by `make down`
