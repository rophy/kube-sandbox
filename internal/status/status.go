package status

import (
	"context"
	"fmt"
	"os"
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
	inGrace, graceReason, clusterAge := c.checkGracePeriod(ctx)
	if inGrace {
		return &Status{
			Status:               "grace_period",
			Reason:               graceReason,
			ClusterAgeMinutes:    clusterAge,
			IdleThresholdMinutes: c.config.IdleThresholdMinutes,
			GracePeriodMinutes:   c.config.GracePeriodMinutes,
		}, nil
	}

	// Check if idle
	isIdle, idleReason := c.checkIdle(ctx)
	status := "active"
	if isIdle {
		status = "idle"
	}

	return &Status{
		Status:               status,
		Reason:               idleReason,
		ClusterAgeMinutes:    clusterAge,
		IdleThresholdMinutes: c.config.IdleThresholdMinutes,
		GracePeriodMinutes:   c.config.GracePeriodMinutes,
	}, nil
}

func (c *Checker) checkGracePeriod(ctx context.Context) (inGrace bool, reason string, ageMinutes *float64) {
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
		return false, fmt.Sprintf("Error checking VPC: %v", err), nil
	}

	if len(result.Vpcs) == 0 {
		return false, "No cluster VPC found", nil
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
		return false, "No creation timestamp found", nil
	}

	createdAt, err := time.Parse(time.RFC3339, createdAtStr)
	if err != nil {
		return false, fmt.Sprintf("Error parsing timestamp: %v", err), nil
	}

	age := time.Since(createdAt).Minutes()
	ageMinutes = &age

	if age < float64(c.config.GracePeriodMinutes) {
		return true, fmt.Sprintf("Cluster is %.1f min old (grace period: %d min)", age, c.config.GracePeriodMinutes), ageMinutes
	}

	return false, fmt.Sprintf("Cluster is %.1f min old (past grace period)", age), ageMinutes
}

func (c *Checker) checkIdle(ctx context.Context) (isIdle bool, reason string) {
	endTime := time.Now().UTC()
	startTime := endTime.Add(-time.Duration(c.config.IdleThresholdMinutes) * time.Minute)

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
		// On error, don't destroy - be safe
		return false, fmt.Sprintf("Error checking metrics: %v", err)
	}

	if len(result.Datapoints) == 0 {
		return true, "No metrics received (EC2 may be stuck or cluster not running)"
	}

	var totalRequests float64
	for _, dp := range result.Datapoints {
		if dp.Sum != nil {
			totalRequests += *dp.Sum
		}
	}

	if totalRequests == 0 {
		return true, fmt.Sprintf("Zero API requests in last %d minutes", c.config.IdleThresholdMinutes)
	}

	return false, fmt.Sprintf("%.0f API requests in last %d minutes", totalRequests, c.config.IdleThresholdMinutes)
}
