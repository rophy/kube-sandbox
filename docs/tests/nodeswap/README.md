# Kubernetes 1.31 NodeSwap Test Plan

## Objective

Test Kubernetes NodeSwap feature to demonstrate that a MariaDB pod with swap enabled survives memory pressure that would OOMKill a pod without swap.

## Environment

- Kubernetes: v1.31.0
- Container Runtime: containerd
- Minikube Driver: kvm2 (required for true memory isolation)
- Nodes: 2 (1 control-plane, 1 worker)
- Node Memory: 3GB each
- Swap: 6GB on worker node only

## Test Configuration

| Setting | Value |
|---------|-------|
| Node memory | 3072Mi |
| Swap size (node 2) | 6144Mi |
| MariaDB memory request | 256Mi |
| MariaDB memory limit | 512Mi |
| Expected swap limit | 512Mi |
| innodb_buffer_pool_size | 410Mi |
| max_connections | 2000 |

### LimitedSwap Formula

```
swapLimit = (containerMemoryRequest / nodeTotalMemory) × totalPodsSwapAvailable
swapLimit = (256Mi / 3072Mi) × 6144Mi = 512Mi
```

---

## Step 1: Create Minikube Cluster

```bash
# Delete existing cluster if any
minikube delete

# Create new cluster with 2 nodes using KVM driver
minikube start \
  --driver=kvm2 \
  --kubernetes-version=v1.31.0 \
  --nodes=2 \
  --memory=3072 \
  --container-runtime=containerd

# Verify cluster
kubectl get nodes
```

---

## Step 2: Configure Swap on Worker Node

### 2.1 Create Swap File

```bash
minikube ssh -n minikube-m02 << 'EOF'
sudo dd if=/dev/zero of=/mnt/vda1/swapfile bs=1M count=6144
sudo chmod 600 /mnt/vda1/swapfile
sudo mkswap /mnt/vda1/swapfile
sudo swapon /mnt/vda1/swapfile

# Verify swap
free -h
EOF
```

### 2.2 Configure Kubelet for Swap

```bash
minikube ssh -n minikube-m02 << 'EOF'
# Backup original config
sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak

# Add swap configuration
sudo tee -a /var/lib/kubelet/config.yaml << 'CONFIG'
failSwapOn: false
featureGates:
  NodeSwap: true
memorySwap:
  swapBehavior: LimitedSwap
CONFIG

# Restart kubelet
sudo systemctl restart kubelet
EOF
```

### 2.3 Label Nodes

```bash
kubectl label node minikube swap=disabled
kubectl label node minikube-m02 swap=enabled

# Verify labels
kubectl get nodes -L swap
```

---

## Step 3: Deploy All Components

All Kubernetes manifests are in the `deploy/` folder. Deploy with:

```bash
kubectl apply -k deploy/
```

This deploys:
- **MariaDB StatefulSets** (`mariadb-no-swap`, `mariadb-with-swap`) with headless services
- **Sysbench Deployment** (single client that can connect to both MariaDB instances)
- **Node Exporter DaemonSet** (in `monitoring` namespace)
- **Prometheus StatefulSet** (in `monitoring` namespace, accessible on NodePort 30090)

### 3.1 Verify Deployments

```bash
# Check MariaDB pods
kubectl get pods -l app=mariadb -o wide

# Check sysbench pod
kubectl get pods -l app=sysbench

# Check monitoring
kubectl get pods -n monitoring

# Verify QoS class is Burstable
kubectl get pod -l app=mariadb -o jsonpath='{range .items[*]}{.metadata.name}: {.status.qosClass}{"\n"}{end}'
```

### 3.2 Wait for All Pods Ready

```bash
kubectl wait --for=condition=Ready pods -l app=mariadb --timeout=120s
kubectl wait --for=condition=Ready pods -l app=sysbench --timeout=60s
kubectl wait --for=condition=Ready pods -l app=node-exporter -n monitoring --timeout=60s
kubectl wait --for=condition=Ready pods -l app=prometheus -n monitoring --timeout=60s
```

---

## Step 4: Configure MariaDB

```bash
# Configure no-swap MariaDB
kubectl exec mariadb-no-swap-0 -- mariadb -uroot -ptestpass -e "
SET GLOBAL innodb_buffer_pool_size = 429916160;
SET GLOBAL max_connections = 2000;
SET GLOBAL max_prepared_stmt_count = 100000;
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SHOW VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE 'max_prepared_stmt_count';
"

# Configure swap MariaDB
kubectl exec mariadb-with-swap-0 -- mariadb -uroot -ptestpass -e "
SET GLOBAL innodb_buffer_pool_size = 429916160;
SET GLOBAL max_connections = 2000;
SET GLOBAL max_prepared_stmt_count = 100000;
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SHOW VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE 'max_prepared_stmt_count';
"
```

---

## Step 5: Verify Metrics Are Available

### 5.1 Node Exporter Metrics

```bash
# Check node-exporter metrics on swap node
minikube ssh -n minikube-m02 -- "curl -s http://localhost:9100/metrics | grep node_vmstat_psw"
```

### 5.2 cAdvisor Metrics

```bash
kubectl get --raw /api/v1/nodes/minikube-m02/proxy/metrics/cadvisor | grep container_memory_swap
```

### 5.3 Prometheus UI

```bash
# Get Prometheus URL
minikube service prometheus -n monitoring --url

# Or port-forward
kubectl port-forward -n monitoring svc/prometheus 9090:9090
```

**Available Metrics:**

| Source | Metric | Description |
|--------|--------|-------------|
| node-exporter | `node_vmstat_pswpin` | Pages swapped in (thrashing) |
| node-exporter | `node_vmstat_pswpout` | Pages swapped out (thrashing) |
| node-exporter | `node_memory_SwapFree_bytes` | Free swap space |
| cAdvisor | `container_memory_swap` | Container swap usage |
| cAdvisor | `container_memory_usage_bytes` | Container memory usage |
| cAdvisor | `container_memory_failcnt` | Memory limit hits |

---

## Step 6: Prepare Sysbench Tables

```bash
# Get sysbench pod name
SYSBENCH_POD=$(kubectl get pod -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

# Prepare tables on no-swap MariaDB
kubectl exec $SYSBENCH_POD -- sysbench oltp_read_write \
  --mysql-host=mariadb-no-swap \
  --mysql-user=root \
  --mysql-password=testpass \
  --mysql-db=testdb \
  --table-size=100000 \
  --tables=4 \
  prepare

# Prepare tables on swap MariaDB
kubectl exec $SYSBENCH_POD -- sysbench oltp_read_write \
  --mysql-host=mariadb-with-swap \
  --mysql-user=root \
  --mysql-password=testpass \
  --mysql-db=testdb \
  --table-size=100000 \
  --tables=4 \
  prepare
```

---

## Step 7: Verify Swap Configuration

### 7.1 Check Cgroup Swap Limits

```bash
# Get container IDs and cgroup paths
NOSWAP_CID=$(kubectl get pod mariadb-no-swap-0 -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
NOSWAP_UID=$(kubectl get pod mariadb-no-swap-0 -o jsonpath='{.metadata.uid}')

SWAP_CID=$(kubectl get pod mariadb-with-swap-0 -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
SWAP_UID=$(kubectl get pod mariadb-with-swap-0 -o jsonpath='{.metadata.uid}')

# Check no-swap pod (should be 0)
minikube ssh -n minikube -- "cat /sys/fs/cgroup/kubepods/burstable/pod${NOSWAP_UID}/${NOSWAP_CID}/memory.swap.max"

# Check swap pod (should be ~512Mi = 536870912)
minikube ssh -n minikube-m02 -- "cat /sys/fs/cgroup/kubepods/burstable/pod${SWAP_UID}/${SWAP_CID}/memory.swap.max"
```

Expected values:
- No-swap pod: `memory.swap.max = 0`
- Swap pod: `memory.swap.max = 536870912` (512Mi)

---

## Step 8: Run Load Tests

### 8.1 Test No-Swap Pod First

```bash
SYSBENCH_POD=$(kubectl get pod -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

# Record baseline restart count
kubectl get pod mariadb-no-swap-0 -o jsonpath='{.status.containerStatuses[0].restartCount}'

# Run sysbench with increasing threads until OOMKill
for THREADS in 100 200 300 400 500; do
  echo "Testing with $THREADS threads..."

  kubectl exec $SYSBENCH_POD -- sysbench oltp_read_write \
    --mysql-host=mariadb-no-swap \
    --mysql-user=root \
    --mysql-password=testpass \
    --mysql-db=testdb \
    --table-size=100000 \
    --tables=4 \
    --threads=$THREADS \
    --time=60 \
    run

  # Check if OOMKilled
  RESTARTS=$(kubectl get pod mariadb-no-swap-0 -o jsonpath='{.status.containerStatuses[0].restartCount}')
  echo "Restart count: $RESTARTS"

  if [ "$RESTARTS" -gt 0 ]; then
    echo "OOMKilled at $THREADS threads!"
    break
  fi
done
```

### 8.2 Test Swap-Enabled Pod

```bash
# Use same thread count that caused OOM on no-swap pod
THREADS=<value from above>

# Run sysbench
kubectl exec $SYSBENCH_POD -- sysbench oltp_read_write \
  --mysql-host=mariadb-with-swap \
  --mysql-user=root \
  --mysql-password=testpass \
  --mysql-db=testdb \
  --table-size=100000 \
  --tables=4 \
  --threads=$THREADS \
  --time=120 \
  run
```

---

## Step 9: Monitor Metrics During Load Test

Run monitoring in separate terminals during load tests.

### 9.1 Monitor via Prometheus

Open Prometheus UI and query:

```promql
# Swap I/O rate (thrashing indicator)
rate(node_vmstat_pswpin[1m])
rate(node_vmstat_pswpout[1m])

# Container memory usage
container_memory_usage_bytes{pod=~"mariadb.*"}

# Container swap usage
container_memory_swap{pod=~"mariadb.*"}

# Memory limit hit count
container_memory_failcnt{pod=~"mariadb.*"}
```

### 9.2 Monitor Node-Exporter Metrics (CLI)

```bash
# Watch swap I/O rate (high values indicate thrashing)
watch -n 1 'minikube ssh -n minikube-m02 -- "curl -s http://localhost:9100/metrics" | grep -E "node_vmstat_psw(pin|pout)"'
```

### 9.3 Monitor cAdvisor Metrics (CLI)

```bash
# Watch container memory and swap usage
watch -n 1 'kubectl get --raw /api/v1/nodes/minikube-m02/proxy/metrics/cadvisor 2>/dev/null | grep -E "container_memory_(swap|usage_bytes).*mariadb-with-swap"'
```

### 9.4 Monitor Cgroup Stats Directly

```bash
# Get cgroup path first
SWAP_CID=$(kubectl get pod mariadb-with-swap-0 -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
SWAP_UID=$(kubectl get pod mariadb-with-swap-0 -o jsonpath='{.metadata.uid}')
CGROUP="/sys/fs/cgroup/kubepods/burstable/pod${SWAP_UID}/${SWAP_CID}"

# Watch memory, swap, and page faults
watch -n 1 "minikube ssh -n minikube-m02 -- \"echo memory: \\\$(cat $CGROUP/memory.current); echo swap: \\\$(cat $CGROUP/memory.swap.current); grep -E 'pgfault|pgmajfault' $CGROUP/memory.stat\""
```

### 9.5 Thrashing Indicators

| Metric | Normal | Thrashing |
|--------|--------|-----------|
| `node_vmstat_pswpin` rate | < 100/s | > 1000/s |
| `node_vmstat_pswpout` rate | < 100/s | > 1000/s |
| `pgmajfault` rate | < 10/s | > 100/s |
| Query latency | < 100ms | > 1000ms |

---

## Expected Results

| Pod | Memory Limit | Swap Limit | Under Pressure |
|-----|--------------|------------|----------------|
| mariadb-no-swap-0 | 512Mi | 0 | OOMKilled |
| mariadb-with-swap-0 | 512Mi | 512Mi | Survives (may thrash) |

---

## Cleanup

```bash
# Delete all deployed resources
kubectl delete -k deploy/

# Delete minikube cluster
minikube delete
```
