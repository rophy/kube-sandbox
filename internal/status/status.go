package status

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

const (
	MetricNamespace = "KubeSandbox"
	MetricName      = "KubeApiRequests"
	VPCName         = "k3s-perf-test-vpc"
	CreatedAtTag    = "kube-sandbox/created-at"
)

type Status struct {
	Status               string   `json:"status"`
	Reason               string   `json:"reason"`
	LastActivityAt       *string  `json:"last_activity_at"`
	IdleSinceMinutes     *float64 `json:"idle_since_minutes"`
	DestroyAt            *string  `json:"destroy_at"`
	ClusterAgeMinutes    *float64 `json:"cluster_age_minutes"`
	IdleThresholdMinutes int      `json:"idle_threshold_minutes"`
	GracePeriodMinutes   int      `json:"grace_period_minutes"`
}

type Config struct {
	IdleThresholdMinutes int
	CheckIntervalMinutes int
	GracePeriodMinutes   int
}

func LoadConfig() Config {
	return Config{
		IdleThresholdMinutes: getEnvInt("IDLE_THRESHOLD_MINUTES", 30),
		CheckIntervalMinutes: getEnvInt("CHECK_INTERVAL_MINUTES", 5),
		GracePeriodMinutes:   getEnvInt("GRACE_PERIOD_MINUTES", 10),
	}
}

func getEnvInt(key string, defaultVal int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return defaultVal
}

type Checker struct {
	cloudwatch *cloudwatch.Client
	ec2        *ec2.Client
	config     Config
}

func NewChecker(ctx context.Context, cfg Config) (*Checker, error) {
	awsCfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("loading AWS config: %w", err)
	}

	return &Checker{
		cloudwatch: cloudwatch.NewFromConfig(awsCfg),
		ec2:        ec2.NewFromConfig(awsCfg),
		config:     cfg,
	}, nil
}

func (c *Checker) GetStatus(ctx context.Context) (*Status, error) {
	// Check grace period first
	inGrace, graceReason, clusterAge, createdAt := c.checkGracePeriod(ctx)
	if inGrace {
		return &Status{
			Status:               "grace_period",
			Reason:               graceReason,
			ClusterAgeMinutes:    clusterAge,
			IdleThresholdMinutes: c.config.IdleThresholdMinutes,
			GracePeriodMinutes:   c.config.GracePeriodMinutes,
		}, nil
	}

	// Check activity and find last active timestamp
	lastActivity, idleSince, isIdle, reason := c.checkActivity(ctx, createdAt)

	status := "active"
	if isIdle {
		status = "idle"
	}

	result := &Status{
		Status:               status,
		Reason:               reason,
		ClusterAgeMinutes:    clusterAge,
		IdleThresholdMinutes: c.config.IdleThresholdMinutes,
		GracePeriodMinutes:   c.config.GracePeriodMinutes,
	}

	if lastActivity != nil {
		ts := lastActivity.Format(time.RFC3339)
		result.LastActivityAt = &ts
		result.IdleSinceMinutes = idleSince

		// Calculate destroy time
		destroyAt := lastActivity.Add(time.Duration(c.config.IdleThresholdMinutes) * time.Minute)
		destroyAtStr := destroyAt.Format(time.RFC3339)
		result.DestroyAt = &destroyAtStr
	}

	return result, nil
}

func (c *Checker) checkGracePeriod(ctx context.Context) (inGrace bool, reason string, ageMinutes *float64, createdAt *time.Time) {
	input := &ec2.DescribeVpcsInput{
		Filters: []ec2types.Filter{
			{
				Name:   aws.String("tag:Name"),
				Values: []string{VPCName},
			},
		},
	}

	result, err := c.ec2.DescribeVpcs(ctx, input)
	if err != nil {
		return false, fmt.Sprintf("Error checking VPC: %v", err), nil, nil
	}

	if len(result.Vpcs) == 0 {
		return false, "No cluster VPC found", nil, nil
	}

	// Find creation timestamp tag
	var createdAtStr string
	for _, tag := range result.Vpcs[0].Tags {
		if aws.ToString(tag.Key) == CreatedAtTag {
			createdAtStr = aws.ToString(tag.Value)
			break
		}
	}

	if createdAtStr == "" {
		return false, "No creation timestamp found", nil, nil
	}

	parsed, err := time.Parse(time.RFC3339, createdAtStr)
	if err != nil {
		return false, fmt.Sprintf("Error parsing timestamp: %v", err), nil, nil
	}

	age := time.Since(parsed).Minutes()
	ageMinutes = &age
	createdAt = &parsed

	if age < float64(c.config.GracePeriodMinutes) {
		return true, fmt.Sprintf("Cluster is %.1f min old (grace period: %d min)", age, c.config.GracePeriodMinutes), ageMinutes, createdAt
	}

	return false, fmt.Sprintf("Cluster is %.1f min old (past grace period)", age), ageMinutes, createdAt
}

func (c *Checker) checkActivity(ctx context.Context, createdAt *time.Time) (lastActivity *time.Time, idleSince *float64, isIdle bool, reason string) {
	// Query metrics for a longer period to find last activity
	endTime := time.Now().UTC()
	// Look back further than idle threshold to find last activity
	lookbackMinutes := c.config.IdleThresholdMinutes * 2
	if lookbackMinutes < 60 {
		lookbackMinutes = 60
	}
	startTime := endTime.Add(-time.Duration(lookbackMinutes) * time.Minute)

	input := &cloudwatch.GetMetricStatisticsInput{
		Namespace:  aws.String(MetricNamespace),
		MetricName: aws.String(MetricName),
		StartTime:  aws.Time(startTime),
		EndTime:    aws.Time(endTime),
		Period:     aws.Int32(int32(c.config.CheckIntervalMinutes * 60)),
		Statistics: []types.Statistic{types.StatisticSum},
	}

	result, err := c.cloudwatch.GetMetricStatistics(ctx, input)
	if err != nil {
		return nil, nil, false, fmt.Sprintf("Error checking metrics: %v", err)
	}

	if len(result.Datapoints) == 0 {
		// No metrics at all - use cluster creation time as last activity
		if createdAt != nil {
			idle := time.Since(*createdAt).Minutes()
			return createdAt, &idle, idle >= float64(c.config.IdleThresholdMinutes), "No metrics received (using cluster creation time)"
		}
		return nil, nil, true, "No metrics received (EC2 may be stuck or cluster not running)"
	}

	// Sort datapoints by timestamp descending
	sort.Slice(result.Datapoints, func(i, j int) bool {
		return result.Datapoints[i].Timestamp.After(*result.Datapoints[j].Timestamp)
	})

	// Find most recent datapoint with activity
	for _, dp := range result.Datapoints {
		if dp.Sum != nil && *dp.Sum > 0 {
			// Activity found at this timestamp
			// The timestamp is the start of the period, activity happened during that period
			// Add half the period to estimate mid-point of activity
			activityTime := dp.Timestamp.Add(time.Duration(c.config.CheckIntervalMinutes/2) * time.Minute)
			idle := time.Since(activityTime).Minutes()
			isIdleNow := idle >= float64(c.config.IdleThresholdMinutes)
			return &activityTime, &idle, isIdleNow, fmt.Sprintf("%.0f requests at %s", *dp.Sum, dp.Timestamp.Format("15:04"))
		}
	}

	// No activity in any datapoints - use oldest datapoint timestamp
	oldestTime := result.Datapoints[len(result.Datapoints)-1].Timestamp
	idle := time.Since(*oldestTime).Minutes()
	return oldestTime, &idle, true, "Zero API requests in lookback period"
}
