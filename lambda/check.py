"""
Check CloudWatch metrics for cluster activity.
If idle (no metrics or zero activity) for threshold period, invoke destroy Lambda.
"""
import os
import boto3
import logging
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

METRIC_NAMESPACE = 'KubeSandbox'
METRIC_NAME = 'KubeApiRequests'
IDLE_THRESHOLD_MINUTES = int(os.environ.get('IDLE_THRESHOLD_MINUTES', '30'))
CHECK_INTERVAL_MINUTES = int(os.environ.get('CHECK_INTERVAL_MINUTES', '5'))
GRACE_PERIOD_MINUTES = int(os.environ.get('GRACE_PERIOD_MINUTES', '10'))


def handler(event, context):
    """
    Check if cluster is idle based on CloudWatch metrics.
    Metrics are published by EC2 cronjob.
    Missing metrics = EC2 stuck = treated as idle.
    """
    enable_auto_destroy = os.environ.get('ENABLE_AUTO_DESTROY', 'false').lower() == 'true'
    destroy_function = os.environ.get('DESTROY_FUNCTION_NAME', 'kube-sandbox-destroy')

    logger.info(f"Checking cluster activity (threshold: {IDLE_THRESHOLD_MINUTES} min)")

    # Check if cluster is in grace period (newly created)
    in_grace, grace_reason = check_grace_period()
    if in_grace:
        logger.info(f"Cluster in grace period: {grace_reason}")
        return {'status': 'grace_period', 'reason': grace_reason}

    is_idle, reason = check_idle()

    if is_idle:
        logger.warning(f"Cluster is idle: {reason}")

        if not enable_auto_destroy:
            logger.warning("DRY RUN: Would trigger destroy, but enable_auto_destroy=false")
            return {'status': 'dry_run', 'idle': True, 'reason': reason}

        # Invoke destroy Lambda
        logger.warning(f"Invoking {destroy_function}...")
        lambda_client = boto3.client('lambda')
        lambda_client.invoke(
            FunctionName=destroy_function,
            InvocationType='Event'  # Async
        )
        return {'status': 'destroy_triggered', 'reason': reason}
    else:
        logger.info(f"Cluster is active: {reason}")
        return {'status': 'active', 'reason': reason}


def check_idle():
    """
    Check CloudWatch metrics for activity.
    Returns (is_idle: bool, reason: str)
    """
    cloudwatch = boto3.client('cloudwatch')

    end_time = datetime.utcnow()
    start_time = end_time - timedelta(minutes=IDLE_THRESHOLD_MINUTES)

    try:
        response = cloudwatch.get_metric_statistics(
            Namespace=METRIC_NAMESPACE,
            MetricName=METRIC_NAME,
            StartTime=start_time,
            EndTime=end_time,
            Period=CHECK_INTERVAL_MINUTES * 60,
            Statistics=['Sum']
        )

        datapoints = response.get('Datapoints', [])

        if not datapoints:
            # No metrics = EC2 not publishing = stuck or not running
            return True, "No metrics received (EC2 may be stuck or cluster not running)"

        # Check if all datapoints are zero
        total_requests = sum(dp.get('Sum', 0) for dp in datapoints)

        if total_requests == 0:
            return True, f"Zero API requests in last {IDLE_THRESHOLD_MINUTES} minutes"
        else:
            return False, f"{int(total_requests)} API requests in last {IDLE_THRESHOLD_MINUTES} minutes"

    except Exception as e:
        logger.error(f"Error checking metrics: {e}")
        # On error, don't destroy - be safe
        return False, f"Error checking metrics: {e}"


def check_grace_period():
    """
    Check if cluster is newly created (within grace period).
    Uses VPC tag 'kube-sandbox/created-at' to determine cluster age.
    Returns (in_grace: bool, reason: str)
    """
    ec2 = boto3.client('ec2')

    try:
        response = ec2.describe_vpcs(
            Filters=[{'Name': 'tag:Name', 'Values': ['k3s-perf-test-vpc']}]
        )

        vpcs = response.get('Vpcs', [])
        if not vpcs:
            # No VPC = no cluster
            return False, "No cluster VPC found"

        # Get creation timestamp from tag
        tags = {t['Key']: t['Value'] for t in vpcs[0].get('Tags', [])}
        created_at_str = tags.get('kube-sandbox/created-at')

        if not created_at_str:
            # No timestamp tag = old cluster, no grace period
            return False, "No creation timestamp found"

        # Parse timestamp and check age
        created_at = datetime.fromisoformat(created_at_str.replace('Z', '+00:00'))
        age_minutes = (datetime.now(timezone.utc) - created_at).total_seconds() / 60

        if age_minutes < GRACE_PERIOD_MINUTES:
            return True, f"Cluster is {age_minutes:.1f} min old (grace period: {GRACE_PERIOD_MINUTES} min)"
        else:
            return False, f"Cluster is {age_minutes:.1f} min old (past grace period)"

    except Exception as e:
        logger.error(f"Error checking grace period: {e}")
        # On error, skip grace period check (be cautious)
        return False, f"Error checking grace period: {e}"
