# Auto-Destroy Implementation Plan

## Goal

Automatically destroy the K8s cluster after a period of idle time to save costs.

## Approach

Use **VPC Flow Logs** to detect external kubectl traffic to the K8s API (port 6443). When no external traffic is detected for X minutes, trigger `terraform destroy`.

### Why VPC Flow Logs?

| Approach | Result |
|----------|--------|
| EC2 `ss` command | Only detects long-running connections, misses short kubectl calls |
| EC2 iptables counters | Unreliable - K3s dynamically manages iptables rules |
| NLB CloudWatch metrics | Reliable but expensive (~$16+/month) |
| **VPC Flow Logs** | Reliable, cheap (<$0.01/day for this workload) |

### Detection Logic

```
External kubectl traffic = VPC Flow Logs where:
  - dstPort = 6443
  - srcAddr NOT like "10.%" (not from VPC CIDR)
```

Internal K8s traffic (kubelet, pods) uses 10.x.x.x addresses and is filtered out.

## Current Status

### Completed

1. **VPC Flow Logs in Terraform** (`terraform/vpc.tf`)
   - CloudWatch Log Group: `/kube-sandbox/vpc-flow-logs` (1 day retention)
   - IAM Role for Flow Logs
   - Flow Log with 60-second aggregation interval

2. **Backend config externalized** (`terraform/versions.tf`, `scripts/init.sh`)
   - S3 bucket name provided via `terraform/backend.tfvars`
   - Example file: `terraform/backend.tfvars.example`

3. **SSH-based access** (no SSM required)
   - SSH key generated in `.ssh/` by `scripts/init.sh`
   - All scripts use SSH instead of SSM

4. **Auto-destroy infrastructure** (all files created)
   - `buildspec.yml` - CodeBuild buildspec
   - `terraform/codebuild.tf` - CodeBuild project
   - `terraform/iam_auto_destroy.tf` - IAM roles for CodeBuild and Lambda
   - `terraform/lambda.tf` - Lambda function and EventBridge schedule
   - `lambda/idle_checker/main.py` - Lambda code (Python 3.12)
   - `terraform/variables.tf` - Added `idle_timeout_minutes` and `enable_auto_destroy`

### Tested & Verified

- VPC Flow Logs capture external kubectl traffic correctly
- Query filters out internal K8s traffic (10.x.x.x)
- Idle detection works: 0 external requests when no kubectl running
- Terraform configuration validates successfully

## Implementation Details

### 1. CodeBuild Project

CodeBuild project that runs `terraform destroy -auto-approve`.

**Decisions:**
- **Source**: GitHub public repo (https://github.com/rophy/kube-sandbox.git)
  - No OAuth/connection needed for public repos
  - Always uses latest code from main branch
- **backend.tfvars**: Environment variable `TF_STATE_BUCKET` set in CodeBuild project
  - Terraform reads local backend.tfvars and passes value to CodeBuild env var
  - buildspec generates backend.tfvars at runtime

**buildspec.yml:**
```yaml
version: 0.2
phases:
  install:
    commands:
      - curl -o terraform.zip https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip
      - unzip terraform.zip && mv terraform /usr/local/bin/
  build:
    commands:
      - cd terraform
      - echo "bucket = \"${TF_STATE_BUCKET}\"" > backend.tfvars
      - terraform init -backend-config=backend.tfvars
      - terraform destroy -auto-approve
```

**Additional decisions:**
- **buildspec.yml location**: In repo at `buildspec.yml`
- **IAM permissions**: AdministratorAccess (dedicated sandbox account, simplicity over least-privilege)
- **Compute type**: BUILD_GENERAL1_SMALL (cheapest, sufficient for terraform destroy)

### 2. Create Lambda for Idle Detection

Lambda function that:
- Runs every 5 minutes (EventBridge schedule)
- Queries CloudWatch Logs Insights for external traffic to port 6443 in last 30 minutes
- If 0 external requests, triggers CodeBuild to run `terraform destroy`

**Decisions:**
- **Runtime**: Python 3.12 (boto3 included)
- **Schedule**: Every 5 minutes
- **Idle timeout**: 30 minutes (configurable via `idle_timeout_minutes` variable)
- **Code location**: `lambda/idle_checker/main.py`

**Query:**
```
fields @timestamp, srcAddr, dstAddr, dstPort
| filter dstPort = 6443
| filter srcAddr not like /^10\./
| stats count(*) as external_requests
```

**IAM permissions for Lambda:**
- `logs:StartQuery`, `logs:GetQueryResults`, `logs:DescribeLogGroups`
- `codebuild:StartBuild`

### 3. Configuration Variables

Add to `terraform/variables.tf`:
```hcl
variable "idle_timeout_minutes" {
  description = "Minutes of idle before auto-destroy"
  default     = 30
}

variable "enable_auto_destroy" {
  description = "Enable auto-destroy on idle. When false, Lambda logs idle detection but doesn't trigger destroy (dry-run mode for testing)."
  default     = false
}
```

**Testing workflow:**
1. Deploy with `enable_auto_destroy = false` (default)
2. Watch CloudWatch Logs to verify idle detection works
3. Set `enable_auto_destroy = true` when ready for real destruction

## Architecture Diagram

```
┌─────────────────┐
│  Dev Container  │
│    (kubectl)    │
└────────┬────────┘
         │ external traffic
         ▼
┌─────────────────┐     ┌──────────────────┐
│   K8s API       │────▶│  VPC Flow Logs   │
│  (port 6443)    │     │  (CloudWatch)    │
└─────────────────┘     └────────┬─────────┘
                                 │
                                 ▼
                        ┌────────────────┐
                        │    Lambda      │
                        │ (every 5 min)  │
                        └────────┬───────┘
                                 │ if idle
                                 ▼
                        ┌────────────────┐
                        │   CodeBuild    │
                        │ (tf destroy)   │
                        └────────────────┘
```

## Files Created/Modified

- [x] `buildspec.yml` - CodeBuild buildspec at repo root
- [x] `terraform/codebuild.tf` - CodeBuild project
- [x] `terraform/iam_auto_destroy.tf` - IAM roles for Lambda and CodeBuild
- [x] `terraform/lambda.tf` - Lambda function and EventBridge rule
- [x] `lambda/idle_checker/main.py` - Lambda function code (Python)
- [x] `terraform/variables.tf` - Add idle timeout and enable flag
- [x] `terraform/versions.tf` - Add archive provider

## Next Steps

1. Deploy with `make up` and test idle detection (dry-run mode)
2. Watch Lambda logs in CloudWatch to verify detection works
3. Set `enable_auto_destroy = true` when ready for real destruction
