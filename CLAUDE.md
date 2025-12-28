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

## Local Docker Registry

The cluster includes a local Docker registry for in-cluster image builds and deployments. It is automatically deployed by `make up`.

### Registry Endpoint

Use the same registry address everywhere: `registry.registry.svc.cluster.local:30500`

The `/etc/hosts` entry is automatically added by `make up`.

### Pushing Images

```bash
docker tag myimage:latest registry.registry.svc.cluster.local:30500/myimage:latest
docker push registry.registry.svc.cluster.local:30500/myimage:latest
```

### Using Images in Kubernetes

Use the same image reference in pod specs:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example
spec:
  containers:
    - name: app
      image: registry.registry.svc.cluster.local:30500/myimage:latest
```

### Building Images Inside the Cluster (Kaniko)

For CI/CD pipelines that build images inside Kubernetes:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-build
spec:
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:latest
      args:
        - "--dockerfile=Dockerfile"
        - "--context=git://github.com/user/repo.git"
        - "--destination=registry.registry.svc.cluster.local:30500/myimage:latest"
        - "--insecure"
  restartPolicy: Never
```

### Checking Registry Contents

```bash
# List repositories
curl -s http://registry.registry.svc.cluster.local:30500/v2/_catalog

# List tags for an image
curl -s http://registry.registry.svc.cluster.local:30500/v2/myimage/tags/list
```

## Important Notes

- All AWS operations require valid credentials (mounted from `~/.aws` or via environment variables)
- On-demand instances are used by default
- The cluster is ephemeral - destroy when done to avoid charges
- EBS volumes created by CSI driver are automatically cleaned up by `make down`
