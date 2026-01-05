#!/bin/bash
#
# Sysbench test runner with metrics collection
#
# Each test run:
#   1. Restarts MariaDB pod (clean baseline)
#   2. Configures MariaDB (max_connections, buffer pool)
#   3. Prepares sysbench tables
#   4. Runs sysbench test
#   5. Collects metrics from Prometheus
#
# Usage: ./run-test.sh <mariadb-host> <threads> [duration]
#
# Arguments:
#   mariadb-host  Target MariaDB service name (mariadb-with-swap or mariadb-no-swap)
#   threads       Number of sysbench threads
#   duration      Test duration in seconds (default: 60)
#
# Workload config (memory-intensive):
#   - table-size: 500000 rows per table (~500MB dataset)
#   - tables: 4
#   - workload: oltp_read_only (forces buffer pool usage)
#
# Examples:
#   ./run-test.sh mariadb-no-swap 50
#   ./run-test.sh mariadb-with-swap 50 120
#

set -e

usage() {
  echo "Usage: $0 <mariadb-host> <threads> [duration]"
  echo ""
  echo "Arguments:"
  echo "  mariadb-host  Target MariaDB service (mariadb-with-swap or mariadb-no-swap)"
  echo "  threads       Number of sysbench threads"
  echo "  duration      Test duration in seconds (default: 60)"
  echo ""
  echo "Examples:"
  echo "  $0 mariadb-no-swap 50"
  echo "  $0 mariadb-with-swap 50 120"
  exit 1
}

if [ -z "$1" ] || [ -z "$2" ]; then
  usage
fi

MYSQL_HOST="$1"
THREADS="$2"
DURATION="${3:-60}"

# Memory-intensive workload config
# Large tables + read-write workload = more buffer pool + transaction log pressure
TABLE_SIZE=500000
TABLES=4
WORKLOAD="oltp_read_write"

# Validate mariadb-host
if [[ "$MYSQL_HOST" != "mariadb-with-swap" && "$MYSQL_HOST" != "mariadb-no-swap" ]]; then
  echo "Error: mariadb-host must be 'mariadb-with-swap' or 'mariadb-no-swap'" >&2
  echo ""
  usage
fi

MARIADB_POD="${MYSQL_HOST}-0"

echo "=== Phase 1: Restart MariaDB pod ===" >&2
kubectl delete pod "$MARIADB_POD" --wait=true >&2
echo "Waiting for pod to be ready..." >&2
kubectl wait --for=condition=Ready pod/"$MARIADB_POD" --timeout=120s >&2

# Wait a bit more for MariaDB to fully initialize
sleep 5

echo "=== Phase 2: Configure MariaDB ===" >&2
# Retry loop for MariaDB configuration (may need time to accept connections)
for i in {1..10}; do
  if kubectl exec "$MARIADB_POD" -- mariadb -uroot -ptestpass -e "
    SET GLOBAL max_connections = 2000;
    SET GLOBAL max_prepared_stmt_count = 100000;
  " >&2 2>/dev/null; then
    echo "MariaDB configured successfully" >&2
    break
  fi
  echo "Waiting for MariaDB to accept connections... ($i/10)" >&2
  sleep 2
done

echo "=== Phase 3: Prepare sysbench tables ===" >&2
SYSBENCH_POD=$(kubectl get pod -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

# Retry loop for sysbench prepare (network may need time to be ready)
for i in {1..10}; do
  if kubectl exec "$SYSBENCH_POD" -- sysbench "$WORKLOAD" \
    --mysql-host="$MYSQL_HOST" \
    --mysql-user=root \
    --mysql-password=testpass \
    --mysql-db=testdb \
    --table-size="$TABLE_SIZE" \
    --tables="$TABLES" \
    prepare >&2 2>/dev/null; then
    echo "Sysbench tables prepared successfully" >&2
    break
  fi
  if [ $i -eq 10 ]; then
    echo "Failed to prepare sysbench tables after 10 attempts" >&2
    exit 1
  fi
  echo "Waiting for MariaDB connection from sysbench... ($i/10)" >&2
  sleep 3
done

echo "=== Phase 4: Run sysbench test ===" >&2

# Get node info
NODE=$(kubectl get pod "$MARIADB_POD" -o jsonpath='{.spec.nodeName}')

# Record start time
START_TIME=$(date +%s)
START_TIME_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Starting test: $THREADS threads, $DURATION seconds" >&2
echo "Target: $MYSQL_HOST on node $NODE" >&2
echo "Start time: $START_TIME_ISO" >&2

# Run sysbench (don't exit on failure - pod may OOMKill)
set +e
SYSBENCH_OUTPUT=$(kubectl exec "$SYSBENCH_POD" -- sysbench "$WORKLOAD" \
  --mysql-host="$MYSQL_HOST" \
  --mysql-user=root \
  --mysql-password=testpass \
  --mysql-db=testdb \
  --table-size="$TABLE_SIZE" \
  --tables="$TABLES" \
  --threads="$THREADS" \
  --time="$DURATION" \
  --thread-init-timeout=300 \
  run 2>&1)
SYSBENCH_EXIT_CODE=$?
set -e

# Record end time
END_TIME=$(date +%s)
END_TIME_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "End time: $END_TIME_ISO" >&2

if [ $SYSBENCH_EXIT_CODE -ne 0 ]; then
  echo "Sysbench exited with code $SYSBENCH_EXIT_CODE (possible OOMKill)" >&2
fi

echo "=== Phase 5: Collect metrics ===" >&2

# Parse sysbench output
TPS=$(echo "$SYSBENCH_OUTPUT" | grep -oP 'transactions:\s+\d+\s+\(\K[0-9.]+' || echo "0")
QPS=$(echo "$SYSBENCH_OUTPUT" | grep -oP 'queries:\s+\d+\s+\(\K[0-9.]+' || echo "0")
AVG_LATENCY=$(echo "$SYSBENCH_OUTPUT" | grep -oP 'avg:\s+\K[0-9.]+' || echo "0")
P95_LATENCY=$(echo "$SYSBENCH_OUTPUT" | grep -oP '95th percentile:\s+\K[0-9.]+' || echo "0")
TOTAL_TIME=$(echo "$SYSBENCH_OUTPUT" | grep -oP 'total time:\s+\K[0-9.]+' || echo "0")

# Check pod status
RESTARTS=$(kubectl get pod "$MARIADB_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
POD_STATUS=$(kubectl get pod "$MARIADB_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
LAST_STATE=$(kubectl get pod "$MARIADB_POD" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")

# Determine outcome
if [ "$LAST_STATE" = "OOMKilled" ] || [ "$POD_STATUS" != "Running" ]; then
  OUTCOME="OOMKilled"
else
  OUTCOME="Survived"
fi

# Query Prometheus for metrics during test period
PROM_POD="prometheus-0"

# Swap I/O rates (pswpout/pswpin)
PSWPOUT_DATA=$(kubectl exec -n monitoring "$PROM_POD" -- sh -c \
  "wget -qO- 'http://localhost:9090/api/v1/query_range?query=rate(node_vmstat_pswpout%5B15s%5D)&start=$START_TIME&end=$END_TIME&step=5'" 2>/dev/null)

PSWPIN_DATA=$(kubectl exec -n monitoring "$PROM_POD" -- sh -c \
  "wget -qO- 'http://localhost:9090/api/v1/query_range?query=rate(node_vmstat_pswpin%5B15s%5D)&start=$START_TIME&end=$END_TIME&step=5'" 2>/dev/null)

# Container memory usage
MEMORY_DATA=$(kubectl exec -n monitoring "$PROM_POD" -- sh -c \
  "wget -qO- 'http://localhost:9090/api/v1/query_range?query=container_memory_usage_bytes%7Bpod%3D%22${MARIADB_POD}%22%2Ccontainer%3D%22mariadb%22%7D&start=$START_TIME&end=$END_TIME&step=5'" 2>/dev/null)

# Container swap usage
SWAP_DATA=$(kubectl exec -n monitoring "$PROM_POD" -- sh -c \
  "wget -qO- 'http://localhost:9090/api/v1/query_range?query=container_memory_swap%7Bpod%3D%22${MARIADB_POD}%22%2Ccontainer%3D%22mariadb%22%7D&start=$START_TIME&end=$END_TIME&step=5'" 2>/dev/null)

# Container CPU usage (rate of cpu seconds)
CPU_DATA=$(kubectl exec -n monitoring "$PROM_POD" -- sh -c \
  "wget -qO- 'http://localhost:9090/api/v1/query_range?query=rate(container_cpu_usage_seconds_total%7Bpod%3D%22${MARIADB_POD}%22%2Ccontainer%3D%22mariadb%22%7D%5B30s%5D)&start=$START_TIME&end=$END_TIME&step=5'" 2>/dev/null)

# Extract time series from Prometheus responses
extract_values() {
  local data="$1"
  local node_filter="$2"
  echo "$data" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for r in d.get('data', {}).get('result', []):
        if '$node_filter' and r.get('metric', {}).get('node') != '$node_filter':
            continue
        print(json.dumps(r.get('values', [])))
        break
except:
    print('[]')
" 2>/dev/null || echo "[]"
}

PSWPOUT_VALUES=$(extract_values "$PSWPOUT_DATA" "$NODE")
PSWPIN_VALUES=$(extract_values "$PSWPIN_DATA" "$NODE")
MEMORY_VALUES=$(extract_values "$MEMORY_DATA" "")
SWAP_VALUES=$(extract_values "$SWAP_DATA" "")
CPU_VALUES=$(extract_values "$CPU_DATA" "")

# Calculate peak values
calc_peak() {
  echo "$1" | python3 -c "
import sys, json
try:
    vals = json.load(sys.stdin)
    if vals:
        print(int(max(float(v[1]) for v in vals)))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0"
}

calc_avg() {
  echo "$1" | python3 -c "
import sys, json
try:
    vals = json.load(sys.stdin)
    if vals:
        print(int(sum(float(v[1]) for v in vals) / len(vals)))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0"
}

PEAK_PSWPOUT=$(calc_peak "$PSWPOUT_VALUES")
PEAK_PSWPIN=$(calc_peak "$PSWPIN_VALUES")
AVG_MEMORY=$(calc_avg "$MEMORY_VALUES")
AVG_SWAP=$(calc_avg "$SWAP_VALUES")
PEAK_MEMORY=$(calc_peak "$MEMORY_VALUES")
PEAK_SWAP=$(calc_peak "$SWAP_VALUES")

# CPU is a rate (0-N cores), calculate as percentage of 1 core
AVG_CPU=$(echo "$CPU_VALUES" | python3 -c "
import sys, json
try:
    vals = json.load(sys.stdin)
    if vals:
        print(round(sum(float(v[1]) for v in vals) / len(vals) * 100, 1))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0")

PEAK_CPU=$(echo "$CPU_VALUES" | python3 -c "
import sys, json
try:
    vals = json.load(sys.stdin)
    if vals:
        print(round(max(float(v[1]) for v in vals) * 100, 1))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0")

# Output JSON result
cat << EOF
{
  "test": {
    "threads": $THREADS,
    "duration": $DURATION,
    "target": "$MYSQL_HOST",
    "node": "$NODE",
    "workload": "$WORKLOAD",
    "table_size": $TABLE_SIZE,
    "tables": $TABLES
  },
  "timing": {
    "start": "$START_TIME_ISO",
    "end": "$END_TIME_ISO",
    "start_epoch": $START_TIME,
    "end_epoch": $END_TIME,
    "actual_duration": $TOTAL_TIME
  },
  "sysbench": {
    "tps": $TPS,
    "qps": $QPS,
    "avg_latency_ms": $AVG_LATENCY,
    "p95_latency_ms": $P95_LATENCY
  },
  "outcome": {
    "status": "$OUTCOME",
    "pod_restarts": $RESTARTS,
    "last_termination_reason": "$LAST_STATE"
  },
  "metrics": {
    "memory": {
      "avg_bytes": $AVG_MEMORY,
      "peak_bytes": $PEAK_MEMORY,
      "avg_mb": $((AVG_MEMORY / 1024 / 1024)),
      "peak_mb": $((PEAK_MEMORY / 1024 / 1024))
    },
    "swap": {
      "avg_bytes": $AVG_SWAP,
      "peak_bytes": $PEAK_SWAP,
      "avg_mb": $((AVG_SWAP / 1024 / 1024)),
      "peak_mb": $((PEAK_SWAP / 1024 / 1024))
    },
    "swap_io": {
      "peak_pswpout_per_sec": $PEAK_PSWPOUT,
      "peak_pswpin_per_sec": $PEAK_PSWPIN
    },
    "cpu": {
      "avg_percent": $AVG_CPU,
      "peak_percent": $PEAK_CPU
    },
    "time_series": {
      "pswpout": $PSWPOUT_VALUES,
      "pswpin": $PSWPIN_VALUES,
      "memory_bytes": $MEMORY_VALUES,
      "swap_bytes": $SWAP_VALUES,
      "cpu_rate": $CPU_VALUES
    }
  }
}
EOF
