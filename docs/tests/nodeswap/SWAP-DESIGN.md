# Swap Disk Design for Kubernetes DB Pods with IOPS Limits

## Problem Statement

Kubernetes NodeSwap feature (LimitedSwap) enables swap for pods to prevent OOMKill. However:

1. **Swap I/O cannot be limited via cgroups** - kswapd runs in root cgroup, which has no io.max
2. **Swap I/O competes with control plane I/O** - etcd, kubelet, container runtime share same disk
3. **Swap thrashing can starve critical components** - DB pods under memory pressure can saturate disk I/O

## Goals

| Goal | Description |
|------|-------------|
| OOMKill protection | DB pods survive memory spikes via swap |
| Backpressure via slowdown | Disk-based swap slows DB under pressure (not zram) |
| Control plane isolation | etcd, kubelet I/O unaffected by swap activity |
| IOPS limiting | Cap swap I/O to prevent disk saturation |
| Single disk support | Work with existing RAID0 without additional hardware |

## Non-Goals

- Swap redundancy (RAID1) - not achievable with single RAID0
- Per-pod swap IOPS limits - kernel limitation (kswapd is shared)

## Architecture

### Overview

Use Network Block Device (NBD) over loopback with traffic control (tc) rate limiting:

```
┌────────────────────────────────────────────────────────────┐
│ Kubernetes Node                                            │
│                                                            │
│  ┌─────────────────┐                                       │
│  │ Control Plane   │                                       │
│  │ - etcd          │──────────────────┐                    │
│  │ - kubelet       │                  │                    │
│  │ - containerd    │                  ↓                    │
│  └─────────────────┘            ┌──────────┐               │
│                                 │  RAID0   │               │
│  ┌─────────────────┐            │  Disk    │               │
│  │ DB Pods (swap)  │            └──────────┘               │
│  │ - mariadb       │                  ↑                    │
│  │ - postgres      │                  │                    │
│  └────────┬────────┘                  │                    │
│           │                           │                    │
│           ↓                           │                    │
│  ┌─────────────────┐                  │                    │
│  │ NBD Client      │                  │                    │
│  │ /dev/nbd0       │                  │                    │
│  │ (swap device)   │                  │                    │
│  └────────┬────────┘                  │                    │
│           │                           │                    │
│           ↓                           │                    │
│  ┌─────────────────┐                  │                    │
│  │ Loopback (lo)   │                  │                    │
│  │ tc rate limit   │◄── IOPS cap      │                    │
│  │ e.g., 50 Mbps   │                  │                    │
│  └────────┬────────┘                  │                    │
│           │                           │                    │
│           ↓                           │                    │
│  ┌─────────────────┐                  │                    │
│  │ NBD Server      │──────────────────┘                    │
│  │ (nbd-server)    │                                       │
│  │ exports file on │                                       │
│  │ RAID0           │                                       │
│  └─────────────────┘                                       │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### I/O Paths

| Component | I/O Path | Rate Limited |
|-----------|----------|--------------|
| etcd | Direct → RAID0 | No (full speed) |
| kubelet | Direct → RAID0 | No (full speed) |
| Container images | Direct → RAID0 | No (full speed) |
| **Swap** | NBD → loopback (tc) → NBD server → RAID0 | **Yes** |

### Why This Works

1. **tc operates at network level** - Not constrained by cgroups
2. **Loopback is a network interface** - tc rules apply to it
3. **NBD traffic is identifiable** - By port (10809) or protocol
4. **Rate limit caps swap throughput** - Regardless of kswapd behavior

## Implementation

### Step 1: Install NBD

```bash
# Ubuntu/Debian
apt-get install nbd-server nbd-client

# RHEL/CentOS
yum install nbd
```

### Step 2: Create Swap Backing File

```bash
# Create 8GB swap file on RAID0
dd if=/dev/zero of=/mnt/raid0/swap.img bs=1G count=8
chmod 600 /mnt/raid0/swap.img
```

### Step 3: Configure NBD Server

```bash
# /etc/nbd-server/config
[generic]
    listenaddr = 127.0.0.1
    port = 10809

[swap]
    exportname = /mnt/raid0/swap.img
    readonly = false
    flush = true
    fua = true
```

```bash
# Start NBD server
systemctl enable nbd-server
systemctl start nbd-server
```

### Step 4: Configure Traffic Control (tc)

```bash
# Create tc rules to limit NBD traffic on loopback
# Limit to 50 Mbps (~6 MB/s, ~1500 IOPS for 4K blocks)

# Clear existing rules
tc qdisc del dev lo root 2>/dev/null || true

# Create HTB qdisc
tc qdisc add dev lo root handle 1: htb default 10

# Unlimited class for non-NBD traffic
tc class add dev lo parent 1: classid 1:10 htb rate 10gbit

# Limited class for NBD traffic
tc class add dev lo parent 1: classid 1:20 htb rate 50mbit ceil 50mbit

# Filter NBD traffic (port 10809) to limited class
tc filter add dev lo parent 1: protocol ip prio 1 u32 \
    match ip dport 10809 0xffff flowid 1:20
tc filter add dev lo parent 1: protocol ip prio 1 u32 \
    match ip sport 10809 0xffff flowid 1:20
```

### Step 5: Connect NBD Client and Enable Swap

```bash
# Load NBD module
modprobe nbd

# Connect to NBD server
nbd-client 127.0.0.1 10809 /dev/nbd0 -name swap

# Format and enable swap
mkswap /dev/nbd0
swapon /dev/nbd0
```

### Step 6: Persist Configuration

```bash
# /etc/modules-load.d/nbd.conf
nbd

# /etc/systemd/system/nbd-swap.service
[Unit]
Description=NBD Swap Device
After=nbd-server.service network.target
Requires=nbd-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe nbd
ExecStart=/bin/bash -c 'nbd-client 127.0.0.1 10809 /dev/nbd0 -name swap && mkswap /dev/nbd0 && swapon /dev/nbd0'
ExecStop=/bin/bash -c 'swapoff /dev/nbd0; nbd-client -d /dev/nbd0'

[Install]
WantedBy=multi-user.target

# /etc/systemd/system/swap-tc-limit.service
[Unit]
Description=TC Rate Limit for Swap
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/swap-tc-setup.sh
ExecStop=/sbin/tc qdisc del dev lo root

[Install]
WantedBy=multi-user.target
```

## Test Environment Setup

This section describes how to set up a local test environment using Multipass VMs and K3s.

### Prerequisites

- Ubuntu host with KVM support
- Multipass installed: `sudo snap install multipass`
- ~15GB RAM available (3 VMs × 3GB + host)
- ~50GB disk space

### Quick Start

```bash
cd docs/tests/nodeswap/scripts

# Create 3-node K3s cluster (labels nodes automatically)
./setup-k3s-multipass.sh up

# Setup NBD swap on worker1
./setup-nbd-swap.sh up

# Get kubeconfig
./setup-k3s-multipass.sh kubeconfig > ~/.kube/k3s-config
export KUBECONFIG=~/.kube/k3s-config

# Verify cluster
kubectl get nodes -L swap
```

### Cluster Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Host Machine                                                │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ k3s-server  │  │ k3s-worker1 │  │ k3s-worker2 │         │
│  │ 2 CPU, 2GB  │  │ 2 CPU, 3GB  │  │ 2 CPU, 3GB  │         │
│  │ swap=       │  │ swap=       │  │ swap=       │         │
│  │   disabled  │  │   enabled   │  │   disabled  │         │
│  │ control     │  │ NBD+tc      │  │ no swap     │         │
│  │ plane       │  │ 50Mbit cap  │  │ baseline    │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Scripts

| Script | Description |
|--------|-------------|
| `setup-k3s-multipass.sh` | Creates 3-node K3s cluster with Multipass |
| `setup-nbd-swap.sh` | Configures NBD swap on k3s-worker1 |
| `run-test.sh` | Runs sysbench test with metrics collection |
| `run-concurrent-test.sh` | Runs concurrent tests on multiple pods |

### setup-k3s-multipass.sh

Creates K3s cluster and labels nodes:

```bash
# Create cluster
./setup-k3s-multipass.sh up

# Check status
./setup-k3s-multipass.sh status

# Get kubeconfig
./setup-k3s-multipass.sh kubeconfig > ~/.kube/k3s-config

# SSH to a node
./setup-k3s-multipass.sh ssh k3s-worker1

# Destroy cluster
./setup-k3s-multipass.sh down
```

Node labels applied automatically:
- `k3s-server`: `swap=disabled`
- `k3s-worker1`: `swap=enabled`
- `k3s-worker2`: `swap=disabled`

### setup-nbd-swap.sh

Configures NBD-based swap with tc rate limiting on k3s-worker1:

```bash
# Setup with defaults (6GB swap, 50Mbit limit)
./setup-nbd-swap.sh up

# Check status
./setup-nbd-swap.sh status

# Disable and cleanup
./setup-nbd-swap.sh down

# Custom configuration
SWAP_SIZE_MB=8192 RATE_LIMIT=100mbit ./setup-nbd-swap.sh up
```

The script performs:
1. Installs nbd-client, nbd-server, iproute2
2. Creates swap backing file
3. Configures NBD server on loopback
4. Sets up tc rate limiting
5. Connects NBD client and enables swap
6. Configures kubelet for NodeSwap with LimitedSwap

### Verification

```bash
# Check nodes
kubectl get nodes -L swap

# Check swap on worker1
./setup-nbd-swap.sh status

# Manual verification
multipass exec k3s-worker1 -- swapon --show
multipass exec k3s-worker1 -- sudo tc -s class show dev lo

# Check kubelet logs for swap
multipass exec k3s-worker1 -- sudo journalctl -u k3s-agent | grep -i swap
```

### Cleanup

```bash
# Disable swap first
./setup-nbd-swap.sh down

# Then destroy cluster
./setup-k3s-multipass.sh down
```

## Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Swap size | 6 GB (test) / 8 GB (prod) | Size of swap backing file |
| Rate limit | 50 Mbps | tc rate limit (~6 MB/s) |
| NBD port | 10809 | NBD server listen port |
| Backing path | /var/lib/nbd-swap/swap.img | Swap file location |

### IOPS Calculation

```
Rate limit (Mbps) → IOPS (4K blocks)
50 Mbps = 6.25 MB/s = ~1,600 IOPS (4K)
100 Mbps = 12.5 MB/s = ~3,200 IOPS (4K)
200 Mbps = 25 MB/s = ~6,400 IOPS (4K)
```

## Trade-offs

### Pros

| Benefit | Description |
|---------|-------------|
| I/O isolation | Control plane unaffected by swap |
| IOPS limiting | Configurable via tc |
| No extra hardware | Uses existing RAID0 |
| Backpressure works | Disk-based, slow = good |
| Simple tooling | Standard Linux tools (nbd, tc) |

### Cons

| Drawback | Description |
|----------|-------------|
| Latency overhead | NBD + loopback adds ~0.1-0.5ms |
| Complexity | More components than direct swap |
| No redundancy | Swap file on RAID0, disk failure = swap loss |
| Single node | NBD server/client on same node |

### Latency Overhead

| Path | Latency |
|------|---------|
| Direct disk | ~0.1 ms (NVMe) |
| NBD loopback | ~0.2-0.6 ms |
| Overhead | ~0.1-0.5 ms |

Acceptable for swap - we want it slow for backpressure.

## Failure Modes

| Failure | Impact | Mitigation |
|---------|--------|------------|
| NBD server crash | Swap unavailable, OOMKill resumes | systemd auto-restart |
| RAID0 disk failure | Swap lost, SIGBUS for swapped pages | Monitor disk health |
| tc rules lost | Swap unlimited, may impact control plane | Persist in systemd |

## Monitoring

### Key Metrics

```bash
# Swap usage
swapon --show
cat /proc/swaps

# NBD traffic rate
tc -s class show dev lo

# Swap I/O
iostat -x 1 /dev/nbd0

# tc drops (if hitting limit)
tc -s qdisc show dev lo
```

### Alerts

| Metric | Threshold | Action |
|--------|-----------|--------|
| Swap usage | > 80% | Scale pods or add memory |
| tc drops | > 0 sustained | Swap demand exceeds limit |
| NBD disconnects | Any | Check nbd-server health |

## Alternatives Considered

| Alternative | Rejected Because |
|-------------|------------------|
| Cgroups io.max | kswapd in root cgroup, can't limit |
| BFQ scheduler | Can't deprioritize root cgroup |
| zram | No disk I/O = no backpressure |
| Separate disk | Requires additional hardware |
| Loop device + io.max | Same cgroup limitation |

## Future Improvements

1. **NBD over Unix socket** - Lower latency than TCP loopback
2. **Multiple swap tiers** - zram (fast) + NBD (slow, capped)
3. **Per-node tuning** - Different limits for different node roles
4. **eBPF rate limiting** - More flexible than tc

## References

- [Linux NBD](https://nbd.sourceforge.io/)
- [tc-htb man page](https://man7.org/linux/man-pages/man8/tc-htb.8.html)
- [Kubernetes NodeSwap](https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory)
- [cgroups v2 io controller](https://docs.kernel.org/admin-guide/cgroup-v2.html#io)
