# Auto-Destroy Implementation Plan (Revised)

## Goal

Automatically destroy the K8s cluster after a period of idle time to save costs.

## Design

Use **nginx with TLS termination** on EC2 to proxy K8s API access. Nginx validates client certificates, rejecting scanners. A cronjob on EC2 monitors nginx access logs for inactivity and triggers Lambda to destroy.

### Why This Design?

| Previous Approach | Problem |
|-------------------|---------|
| VPC Flow Logs | Layer 4 only - can't distinguish scanners from real kubectl |
| K8s Audit Logs | Would conflict with user testing audit features |

| New Approach | Benefit |
|--------------|---------|
| Nginx TLS termination | Layer 7 visibility, client cert validation |
| EC2 cronjob | Simple, no CloudWatch Logs needed |
| Lambda on-demand | Only runs when triggered, not periodic |

### Architecture

```
                                    ┌─────────────────────────────────┐
                                    │           EC2 (K3s)             │
                                    │                                 │
External kubectl ──────────────────▶│  :16443 nginx (TLS term)        │
(with client cert)                  │      │                          │
                                    │      ▼                          │
                                    │  :6443 K3s API (localhost)      │
                                    │                                 │
Scanner ───────────────────────────▶│  :16443 nginx ──▶ 400 rejected  │
(no client cert)                    │                                 │
                                    │  cronjob ──▶ check access.log   │
                                    │      │                          │
                                    │      ▼ (if idle)                │
                                    │  invoke Lambda ─────────────────┼──▶ terraform destroy
                                    └─────────────────────────────────┘
```

## Implementation Steps

### 1. Remove VPC Flow Logs

Delete from terraform:
- `aws_flow_log.main`
- `aws_cloudwatch_log_group.flow_logs`
- `aws_iam_role.flow_logs`
- `aws_iam_role_policy.flow_logs`

### 2. Configure Nginx on EC2

Add to K3s server user_data:

```bash
# Install nginx
dnf install -y nginx nginx-mod-stream

# Copy K3s certs for nginx
mkdir -p /etc/nginx/ssl
cp /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt /etc/nginx/ssl/server.crt
cp /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key /etc/nginx/ssl/server.key
cp /var/lib/rancher/k3s/server/tls/client-ca.crt /etc/nginx/ssl/client-ca.crt
cp /var/lib/rancher/k3s/server/tls/client-admin.crt /etc/nginx/ssl/client-admin.crt
cp /var/lib/rancher/k3s/server/tls/client-admin.key /etc/nginx/ssl/client-admin.key
chmod 600 /etc/nginx/ssl/*.key

# Nginx config
cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format k8s '$remote_addr [$time_local] "$request" $status $body_bytes_sent $ssl_client_s_dn';

    server {
        listen 16443 ssl;

        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        ssl_client_certificate /etc/nginx/ssl/client-ca.crt;
        ssl_verify_client on;

        access_log /var/log/nginx/k8s-access.log k8s;

        location / {
            proxy_pass https://127.0.0.1:6443;
            proxy_ssl_certificate /etc/nginx/ssl/client-admin.crt;
            proxy_ssl_certificate_key /etc/nginx/ssl/client-admin.key;
            proxy_ssl_verify off;

            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
EOF

systemctl enable --now nginx
```

### 3. Update Security Group

Change terraform security group:
- Remove: ingress port 6443 from 0.0.0.0/0
- Add: ingress port 16443 from 0.0.0.0/0
- Keep: port 6443 internal only (for node communication)

### 4. Configure K3s to Use Localhost

Modify K3s to bind API to localhost:
```bash
# /etc/rancher/k3s/config.yaml
bind-address: "127.0.0.1"
```

Or use TLS-SAN for the Elastic IP but only expose via nginx.

### 5. Add Idle Check Cronjob

Add to user_data:

```bash
cat > /usr/local/bin/check-idle.sh << 'EOF'
#!/bin/bash
IDLE_MINUTES=${IDLE_MINUTES:-30}
LOG_FILE="/var/log/nginx/k8s-access.log"
LAMBDA_FUNCTION="kube-sandbox-idle-checker"

# Count successful requests (status 200, has client cert) in last N minutes
RECENT_REQUESTS=$(awk -v cutoff="$(date -d "-${IDLE_MINUTES} minutes" '+%d/%b/%Y:%H:%M')" '
  $2 >= "["cutoff && $5 == "200" && $7 != "-" { count++ }
  END { print count+0 }
' "$LOG_FILE")

if [ "$RECENT_REQUESTS" -eq 0 ]; then
    echo "Cluster idle for ${IDLE_MINUTES} minutes. Triggering destroy."
    aws lambda invoke --function-name "$LAMBDA_FUNCTION" /tmp/lambda-out.json
fi
EOF

chmod +x /usr/local/bin/check-idle.sh

# Run every 5 minutes
echo "*/5 * * * * root /usr/local/bin/check-idle.sh >> /var/log/idle-check.log 2>&1" > /etc/cron.d/idle-check
```

### 6. Simplify Lambda

Lambda no longer queries logs. Just runs terraform destroy:

```python
def handler(event, context):
    """Triggered by EC2 when idle detected. Runs terraform destroy."""
    if os.environ.get('ENABLE_AUTO_DESTROY', 'false').lower() != 'true':
        return {'status': 'dry_run', 'message': 'Auto-destroy disabled'}

    success, output = run_terraform_destroy(os.environ['TF_STATE_BUCKET'])
    return {'status': 'destroyed' if success else 'failed', 'output': output[-1000:]}
```

Remove from Lambda:
- CloudWatch Logs query logic
- Periodic EventBridge trigger

### 7. Update Kubeconfig Fetch

Update `scripts/fetch-kubeconfig.sh` to use port 16443:
```bash
# Change server URL from 6443 to 16443
sed -i 's/:6443/:16443/' ~/.kube/config
```

### 8. Remove Unused Resources

Delete from terraform:
- `aws_cloudwatch_event_rule.idle_checker` (no more periodic trigger)
- `aws_cloudwatch_event_target.idle_checker`
- `aws_lambda_permission.idle_checker`
- VPC Flow Logs resources (step 1)

## Log Format

Nginx access log format:
```
118.168.198.138 [18/Jan/2026:06:16:21 +0000] "GET /api/v1/nodes?limit=500 HTTP/1.1" 200 14720 CN=system:admin,O=system:masters
```

| Field | Example | Use |
|-------|---------|-----|
| IP | 118.168.198.138 | Client IP |
| Time | 18/Jan/2026:06:16:21 | For idle window |
| Request | GET /api/v1/nodes | Layer 7 visibility |
| Status | 200 | Filter success only |
| Bytes | 14720 | - |
| Client DN | CN=system:admin | Proves authenticated |

## Testing

1. Deploy with `enable_auto_destroy = false`
2. Verify kubectl works via port 16443
3. Verify scanners get 400 rejected
4. Watch `/var/log/idle-check.log` on EC2
5. Set `enable_auto_destroy = true` and wait for destroy

## Files to Modify

- [ ] `terraform/vpc.tf` - Remove VPC Flow Logs
- [ ] `terraform/ec2.tf` - Add nginx setup to user_data
- [ ] `terraform/security.tf` - Change 6443 to 16443
- [ ] `terraform/lambda.tf` - Remove EventBridge trigger
- [ ] `terraform/iam_auto_destroy.tf` - Simplify Lambda IAM (no logs access needed)
- [ ] `lambda/idle_checker/main.py` - Remove log query, just destroy
- [ ] `scripts/fetch-kubeconfig.sh` - Use port 16443
- [ ] `terraform/outputs.tf` - Update port in commands
