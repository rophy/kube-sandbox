import os
import time
import logging
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

logs_client = boto3.client('logs')
codebuild_client = boto3.client('codebuild')


def handler(event, context):
    """
    Check for external kubectl traffic to the K8s API.
    If no traffic detected in the idle timeout period, trigger destroy.
    """
    log_group = os.environ['LOG_GROUP_NAME']
    idle_timeout_minutes = int(os.environ['IDLE_TIMEOUT_MINUTES'])
    codebuild_project = os.environ['CODEBUILD_PROJECT_NAME']
    enable_auto_destroy = os.environ.get('ENABLE_AUTO_DESTROY', 'false').lower() == 'true'

    logger.info(f"Checking for idle state: log_group={log_group}, "
                f"idle_timeout={idle_timeout_minutes}min, "
                f"enable_auto_destroy={enable_auto_destroy}")

    # Check if log group exists (cluster might already be destroyed)
    if not log_group_exists(log_group):
        logger.info(f"Log group {log_group} does not exist. Cluster likely already destroyed. Skipping.")
        return {'status': 'skipped', 'reason': 'log_group_not_found'}

    # Query for external traffic to port 6443 in the idle timeout period
    external_requests = query_external_traffic(log_group, idle_timeout_minutes)

    if external_requests > 0:
        logger.info(f"Cluster is active: {external_requests} external requests in last {idle_timeout_minutes} minutes")
        return {'status': 'active', 'external_requests': external_requests}

    # No external traffic - cluster is idle
    logger.warning(f"Cluster is IDLE: 0 external requests in last {idle_timeout_minutes} minutes")

    if enable_auto_destroy:
        logger.warning(f"Triggering CodeBuild project: {codebuild_project}")
        response = codebuild_client.start_build(projectName=codebuild_project)
        build_id = response['build']['id']
        logger.warning(f"CodeBuild started: {build_id}")
        return {'status': 'destroy_triggered', 'build_id': build_id}
    else:
        logger.warning("DRY RUN: Would trigger destroy, but enable_auto_destroy=false")
        return {'status': 'dry_run', 'would_destroy': True}


def log_group_exists(log_group_name):
    """Check if the log group exists."""
    try:
        response = logs_client.describe_log_groups(logGroupNamePrefix=log_group_name)
        for group in response.get('logGroups', []):
            if group['logGroupName'] == log_group_name:
                return True
        return False
    except Exception as e:
        logger.error(f"Error checking log group: {e}")
        return False


def query_external_traffic(log_group, idle_timeout_minutes):
    """
    Query CloudWatch Logs Insights for external traffic to port 6443.
    Returns the count of external requests.
    """
    query = """
        fields @timestamp, srcAddr, dstAddr, dstPort
        | filter dstPort = 6443
        | filter srcAddr not like /^10\\./
        | stats count(*) as external_requests
    """

    end_time = int(time.time())
    start_time = end_time - (idle_timeout_minutes * 60)

    logger.info(f"Querying logs from {start_time} to {end_time}")

    # Start the query
    response = logs_client.start_query(
        logGroupName=log_group,
        startTime=start_time,
        endTime=end_time,
        queryString=query
    )
    query_id = response['queryId']

    # Wait for query to complete
    while True:
        response = logs_client.get_query_results(queryId=query_id)
        status = response['status']

        if status == 'Complete':
            break
        elif status in ['Failed', 'Cancelled']:
            logger.error(f"Query failed with status: {status}")
            return -1

        time.sleep(1)

    # Parse results
    results = response.get('results', [])
    if not results:
        return 0

    # Results format: [[{'field': 'external_requests', 'value': '5'}]]
    for row in results:
        for field in row:
            if field.get('field') == 'external_requests':
                return int(field.get('value', 0))

    return 0
