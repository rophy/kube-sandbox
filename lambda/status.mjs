/**
 * Status and Check Lambda handlers.
 *
 * checkHandler: Scheduled invocation, triggers destroy if idle
 * statusHandler: API Gateway, returns status JSON
 */
import { CloudWatchClient, GetMetricStatisticsCommand } from '@aws-sdk/client-cloudwatch';
import { EC2Client, DescribeVpcsCommand } from '@aws-sdk/client-ec2';
import { LambdaClient, InvokeCommand } from '@aws-sdk/client-lambda';

// Config from environment
const IDLE_THRESHOLD_MINUTES = parseInt(process.env.IDLE_THRESHOLD_MINUTES || '30');
const CHECK_INTERVAL_MINUTES = parseInt(process.env.CHECK_INTERVAL_MINUTES || '5');
const GRACE_PERIOD_MINUTES = parseInt(process.env.GRACE_PERIOD_MINUTES || '10');
const DESTROY_FUNCTION_NAME = process.env.DESTROY_FUNCTION_NAME || 'kube-sandbox-destroy';
const ENABLE_AUTO_DESTROY = (process.env.ENABLE_AUTO_DESTROY || 'false').toLowerCase() === 'true';

const METRIC_NAMESPACE = 'KubeSandbox';
const METRIC_NAME = 'KubeApiRequests';
const VPC_NAME = 'k3s-perf-test-vpc';
const CREATED_AT_TAG = 'kube-sandbox/created-at';

const cloudwatch = new CloudWatchClient();
const ec2 = new EC2Client();
const lambda = new LambdaClient();

export async function checkHandler(event, context) {
  const status = await getStatus();

  if (status.status === 'grace_period') {
    console.log(`Cluster in grace period: ${status.reason}`);
    return { status: 'grace_period', reason: status.reason };
  }

  if (status.status === 'idle') {
    console.log(`Cluster is idle: ${status.reason}`);

    if (!ENABLE_AUTO_DESTROY) {
      console.log('DRY RUN: Would trigger destroy, but ENABLE_AUTO_DESTROY=false');
      return { status: 'dry_run', idle: true, reason: status.reason };
    }

    console.log(`Invoking ${DESTROY_FUNCTION_NAME}...`);
    await lambda.send(new InvokeCommand({
      FunctionName: DESTROY_FUNCTION_NAME,
      InvocationType: 'Event'
    }));
    return { status: 'destroy_triggered', reason: status.reason };
  }

  console.log(`Cluster is active: ${status.reason}`);
  return { status: 'active', reason: status.reason };
}

export async function statusHandler(event, context) {
  const status = await getStatus();
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(status)
  };
}

async function getStatus() {
  const now = new Date();

  const { inGrace, graceReason, clusterAge, createdAt } = await checkGracePeriod(now);

  if (inGrace) {
    return {
      status: 'grace_period',
      reason: graceReason,
      cluster_age_minutes: clusterAge,
      idle_threshold_minutes: IDLE_THRESHOLD_MINUTES,
      grace_period_minutes: GRACE_PERIOD_MINUTES
    };
  }

  const { lastActivity, idleSince, isIdle, reason } = await checkActivity(now, createdAt);

  const result = {
    status: isIdle ? 'idle' : 'active',
    reason,
    cluster_age_minutes: clusterAge,
    idle_threshold_minutes: IDLE_THRESHOLD_MINUTES,
    grace_period_minutes: GRACE_PERIOD_MINUTES
  };

  if (lastActivity) {
    result.last_activity_at = lastActivity.toISOString();
    result.idle_since_minutes = idleSince;
    const destroyAt = new Date(lastActivity.getTime() + IDLE_THRESHOLD_MINUTES * 60 * 1000);
    result.destroy_at = destroyAt.toISOString();
  }

  return result;
}

async function checkGracePeriod(now) {
  try {
    const response = await ec2.send(new DescribeVpcsCommand({
      Filters: [{ Name: 'tag:Name', Values: [VPC_NAME] }]
    }));

    const vpcs = response.Vpcs || [];
    if (vpcs.length === 0) {
      return { inGrace: false, graceReason: 'No cluster VPC found', clusterAge: null, createdAt: null };
    }

    const tags = {};
    for (const t of vpcs[0].Tags || []) {
      tags[t.Key] = t.Value;
    }
    const createdAtStr = tags[CREATED_AT_TAG];

    if (!createdAtStr) {
      return { inGrace: false, graceReason: 'No creation timestamp found', clusterAge: null, createdAt: null };
    }

    const createdAt = new Date(createdAtStr);
    const ageMinutes = (now - createdAt) / (60 * 1000);

    if (ageMinutes < GRACE_PERIOD_MINUTES) {
      return {
        inGrace: true,
        graceReason: `Cluster is ${ageMinutes.toFixed(1)} min old (grace period: ${GRACE_PERIOD_MINUTES} min)`,
        clusterAge: ageMinutes,
        createdAt
      };
    }

    return {
      inGrace: false,
      graceReason: `Cluster is ${ageMinutes.toFixed(1)} min old`,
      clusterAge: ageMinutes,
      createdAt
    };
  } catch (e) {
    return { inGrace: false, graceReason: `Error checking grace period: ${e}`, clusterAge: null, createdAt: null };
  }
}

async function checkActivity(now, createdAt) {
  const lookbackMinutes = Math.max(IDLE_THRESHOLD_MINUTES * 2, 60);
  const startTime = new Date(now.getTime() - lookbackMinutes * 60 * 1000);

  try {
    const response = await cloudwatch.send(new GetMetricStatisticsCommand({
      Namespace: METRIC_NAMESPACE,
      MetricName: METRIC_NAME,
      StartTime: startTime,
      EndTime: now,
      Period: CHECK_INTERVAL_MINUTES * 60,
      Statistics: ['Sum']
    }));

    const allDatapoints = response.Datapoints || [];
    // Drop datapoints from before this cluster was created — CloudWatch retains
    // metrics across cluster rebuilds and a stale point from a prior cluster
    // would otherwise be treated as current activity (issue #4).
    const datapoints = createdAt
      ? allDatapoints.filter(dp => dp.Timestamp >= createdAt)
      : allDatapoints;

    if (datapoints.length === 0) {
      if (createdAt) {
        const idle = (now - createdAt) / (60 * 1000);
        return {
          lastActivity: createdAt,
          idleSince: idle,
          isIdle: idle >= IDLE_THRESHOLD_MINUTES,
          reason: 'No metrics (using cluster creation time)'
        };
      }
      return { lastActivity: null, idleSince: null, isIdle: true, reason: 'No metrics received' };
    }

    datapoints.sort((a, b) => b.Timestamp - a.Timestamp);

    for (const dp of datapoints) {
      if ((dp.Sum || 0) > 0) {
        const activityTime = new Date(dp.Timestamp.getTime() + (CHECK_INTERVAL_MINUTES / 2) * 60 * 1000);
        const idle = (now - activityTime) / (60 * 1000);
        const isIdle = idle >= IDLE_THRESHOLD_MINUTES;
        const hours = dp.Timestamp.getUTCHours().toString().padStart(2, '0');
        const mins = dp.Timestamp.getUTCMinutes().toString().padStart(2, '0');
        return {
          lastActivity: activityTime,
          idleSince: idle,
          isIdle,
          reason: `${Math.floor(dp.Sum)} requests at ${hours}:${mins}`
        };
      }
    }

    const oldest = datapoints[datapoints.length - 1].Timestamp;
    const idle = (now - oldest) / (60 * 1000);
    return { lastActivity: oldest, idleSince: idle, isIdle: true, reason: 'Zero API requests in lookback period' };
  } catch (e) {
    return { lastActivity: null, idleSince: null, isIdle: false, reason: `Error checking metrics: ${e}` };
  }
}
