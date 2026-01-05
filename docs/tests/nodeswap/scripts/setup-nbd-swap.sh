#!/bin/bash
#
# Setup NBD-based swap with tc rate limiting on k3s-worker1
#
# This script configures:
#   1. NBD server serving a swap file over loopback
#   2. tc qdisc for rate limiting (default 50Mbit)
#   3. NBD client connecting to the server
#   4. Swap enabled on the NBD device
#   5. Kubelet configured for NodeSwap with LimitedSwap
#
# Usage:
#   ./setup-nbd-swap.sh [up|down|status]
#
# Options:
#   SWAP_SIZE_MB   Swap file size in MB (default: 2048)
#   RATE_LIMIT     tc rate limit (default: 50mbit)
#
# Prerequisites:
#   - k3s-worker1 VM must exist (created by setup-k3s-multipass.sh)
#   - Run from host machine with multipass access
#

set -e

# Configuration
WORKER_NAME="k3s-worker1"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-6144}"
RATE_LIMIT="${RATE_LIMIT:-50mbit}"
NBD_PORT=10809
SWAP_FILE="/var/swap/nbd-swap.img"
NBD_DEVICE="/dev/nbd0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_multipass() {
  if ! command -v multipass &> /dev/null; then
    log_error "multipass not installed. Install with: sudo snap install multipass"
    exit 1
  fi
}

check_worker_exists() {
  if ! multipass info "$WORKER_NAME" &>/dev/null; then
    log_error "VM $WORKER_NAME not found. Run setup-k3s-multipass.sh first."
    exit 1
  fi
}

# Install required packages
install_packages() {
  log_info "Installing required packages on $WORKER_NAME..."
  multipass exec "$WORKER_NAME" -- sudo apt-get update -qq
  multipass exec "$WORKER_NAME" -- sudo apt-get install -y -qq nbd-client nbd-server iproute2
}

# Create swap file
create_swap_file() {
  log_info "Creating ${SWAP_SIZE_MB}MB swap file..."
  multipass exec "$WORKER_NAME" -- sudo mkdir -p /var/swap
  multipass exec "$WORKER_NAME" -- sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
  multipass exec "$WORKER_NAME" -- sudo chmod 600 "$SWAP_FILE"
}

# Configure NBD server
configure_nbd_server() {
  log_info "Configuring NBD server..."
  multipass exec "$WORKER_NAME" -- sudo bash -c "cat > /etc/nbd-server/config << 'EOF'
[generic]
  listenaddr = 127.0.0.1
  port = $NBD_PORT

[swap]
  exportname = $SWAP_FILE
  readonly = false
  multifile = false
  copyonwrite = false
  flush = true
  fua = true
EOF"

  # Start NBD server
  log_info "Starting NBD server..."
  multipass exec "$WORKER_NAME" -- sudo systemctl restart nbd-server
  multipass exec "$WORKER_NAME" -- sudo systemctl enable nbd-server
}

# Setup tc rate limiting on loopback
setup_tc_rate_limit() {
  log_info "Setting up tc rate limiting ($RATE_LIMIT) on loopback..."

  # Remove existing qdisc if any
  multipass exec "$WORKER_NAME" -- sudo tc qdisc del dev lo root 2>/dev/null || true

  # Add HTB qdisc with rate limit
  multipass exec "$WORKER_NAME" -- sudo tc qdisc add dev lo root handle 1: htb default 10
  multipass exec "$WORKER_NAME" -- sudo tc class add dev lo parent 1: classid 1:10 htb rate "$RATE_LIMIT" ceil "$RATE_LIMIT"

  # Filter for NBD port
  multipass exec "$WORKER_NAME" -- sudo tc filter add dev lo parent 1: protocol ip prio 1 u32 \
    match ip dport "$NBD_PORT" 0xffff flowid 1:10
  multipass exec "$WORKER_NAME" -- sudo tc filter add dev lo parent 1: protocol ip prio 1 u32 \
    match ip sport "$NBD_PORT" 0xffff flowid 1:10
}

# Connect NBD client and enable swap
connect_nbd_and_enable_swap() {
  log_info "Loading nbd kernel module..."
  multipass exec "$WORKER_NAME" -- sudo modprobe nbd

  # Disconnect if already connected
  multipass exec "$WORKER_NAME" -- sudo nbd-client -d "$NBD_DEVICE" 2>/dev/null || true

  log_info "Connecting NBD client to server..."
  multipass exec "$WORKER_NAME" -- sudo nbd-client 127.0.0.1 "$NBD_PORT" "$NBD_DEVICE" -name swap

  log_info "Formatting as swap..."
  multipass exec "$WORKER_NAME" -- sudo mkswap "$NBD_DEVICE"

  log_info "Enabling swap..."
  multipass exec "$WORKER_NAME" -- sudo swapon "$NBD_DEVICE"
}

# Configure kubelet for NodeSwap
configure_kubelet() {
  log_info "Configuring kubelet for NodeSwap with LimitedSwap..."

  # Create kubelet config drop-in directory if it doesn't exist
  multipass exec "$WORKER_NAME" -- sudo mkdir -p /var/lib/rancher/k3s/agent/etc/kubelet.conf.d

  # Add swap configuration
  multipass exec "$WORKER_NAME" -- sudo bash -c "cat > /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/10-swap.conf << 'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
memorySwap:
  swapBehavior: LimitedSwap
EOF"

  log_info "Restarting k3s-agent to apply swap configuration..."
  multipass exec "$WORKER_NAME" -- sudo systemctl restart k3s-agent

  # Wait for node to be ready
  log_info "Waiting for node to be ready..."
  sleep 10
}

# Cleanup and disable swap
cmd_down() {
  check_multipass
  check_worker_exists

  log_info "Disabling NBD swap on $WORKER_NAME..."

  # Disable swap
  multipass exec "$WORKER_NAME" -- sudo swapoff "$NBD_DEVICE" 2>/dev/null || true

  # Disconnect NBD client
  multipass exec "$WORKER_NAME" -- sudo nbd-client -d "$NBD_DEVICE" 2>/dev/null || true

  # Stop NBD server
  multipass exec "$WORKER_NAME" -- sudo systemctl stop nbd-server 2>/dev/null || true

  # Remove tc qdisc
  multipass exec "$WORKER_NAME" -- sudo tc qdisc del dev lo root 2>/dev/null || true

  # Remove swap file
  multipass exec "$WORKER_NAME" -- sudo rm -f "$SWAP_FILE" 2>/dev/null || true

  # Remove kubelet swap config
  multipass exec "$WORKER_NAME" -- sudo rm -f /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/10-swap.conf 2>/dev/null || true

  log_info "NBD swap disabled"
}

# Show status
cmd_status() {
  check_multipass
  check_worker_exists

  echo "=== NBD Swap Status on $WORKER_NAME ==="
  echo ""

  echo "--- Swap ---"
  multipass exec "$WORKER_NAME" -- cat /proc/swaps 2>/dev/null || echo "No swap configured"
  echo ""

  echo "--- NBD Server ---"
  multipass exec "$WORKER_NAME" -- systemctl is-active nbd-server 2>/dev/null || echo "Not running"
  echo ""

  echo "--- NBD Device ---"
  multipass exec "$WORKER_NAME" -- sudo nbd-client -c "$NBD_DEVICE" 2>/dev/null && echo "Connected" || echo "Not connected"
  echo ""

  echo "--- TC Rate Limiting ---"
  multipass exec "$WORKER_NAME" -- tc qdisc show dev lo 2>/dev/null || echo "No qdisc configured"
  echo ""

  echo "--- Memory Info ---"
  multipass exec "$WORKER_NAME" -- free -h
}

# Setup everything
cmd_up() {
  check_multipass
  check_worker_exists

  log_info "Setting up NBD-based swap on $WORKER_NAME..."
  log_info "Configuration: ${SWAP_SIZE_MB}MB swap, ${RATE_LIMIT} rate limit"
  echo ""

  install_packages
  create_swap_file
  configure_nbd_server
  setup_tc_rate_limit
  connect_nbd_and_enable_swap
  configure_kubelet

  echo ""
  log_info "NBD swap setup complete!"
  echo ""
  cmd_status
}

# Main
case "${1:-up}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 [up|down|status]"
    echo ""
    echo "Environment variables:"
    echo "  SWAP_SIZE_MB   Swap file size in MB (default: 2048)"
    echo "  RATE_LIMIT     tc rate limit (default: 50mbit)"
    echo ""
    echo "Examples:"
    echo "  $0 up                    # Setup with defaults"
    echo "  RATE_LIMIT=100mbit $0 up # Setup with 100Mbit limit"
    echo "  $0 status                # Show current status"
    echo "  $0 down                  # Disable and cleanup"
    exit 1
    ;;
esac
