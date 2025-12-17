# Claude Instructions for kube-sandbox

## Environment Check (MANDATORY - DO THIS FIRST)

**Immediately upon starting, perform these two checks:**

### 1. Check if inside the dev container:

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

### 2. Check for other Claude processes:

```bash
ps aux | grep -i claude | grep -v grep
```

If more than one Claude process is running, display this warning and STOP:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║   ⚠️  WARNING: MULTIPLE CLAUDE PROCESSES DETECTED                            ║
║                                                                              ║
║   Running multiple Claude processes simultaneously can cause conflicts       ║
║   with Terraform state and AWS resource management.                          ║
║                                                                              ║
║   Please terminate other Claude processes before proceeding:                 ║
║                                                                              ║
║       pkill -f claude      # Kill all Claude processes                       ║
║       claude               # Then restart a single instance                  ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**Do not proceed with any infrastructure or Kubernetes operations until both checks pass.**

## About This Environment

This is a disposable K3s cluster on AWS with minimal cost. The dev container provides all necessary tools:

- **Terraform** - Infrastructure provisioning
- **AWS CLI** - AWS operations
- **kubectl** - Kubernetes management

## Project Structure

- `terraform/` - Infrastructure as Code for AWS EC2 + K3s
- `scripts/` - Helper scripts (fetch-kubeconfig.sh)

## Common Tasks

### Create Infrastructure
```bash
cd terraform
terraform init
terraform apply
```

### Get Kubeconfig
```bash
./scripts/fetch-kubeconfig.sh
export KUBECONFIG=/workspace/kubeconfig.yaml
```

### Deploy Workloads
```bash
./scripts/deploy-workloads.sh
```

### Destroy Everything
```bash
cd terraform
terraform destroy
```

## Important Notes

- All AWS operations require valid credentials (mounted from `~/.aws` or via environment variables)
- Spot instances are used by default for cost savings
- The cluster is ephemeral - destroy when done to avoid charges
