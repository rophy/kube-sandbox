package main

import (
	"context"
	"log"
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	lambdasvc "github.com/aws/aws-sdk-go-v2/service/lambda"
	"github.com/rophy/kube-sandbox/internal/status"
)

type Response struct {
	Status string `json:"status"`
	Reason string `json:"reason"`
	Idle   bool   `json:"idle,omitempty"`
}

func handler(ctx context.Context) (*Response, error) {
	enableAutoDestroy := os.Getenv("ENABLE_AUTO_DESTROY") == "true"
	destroyFunction := os.Getenv("DESTROY_FUNCTION_NAME")
	if destroyFunction == "" {
		destroyFunction = "kube-sandbox-destroy"
	}

	cfg := status.LoadConfig()
	log.Printf("Checking cluster activity (threshold: %d min)", cfg.IdleThresholdMinutes)

	checker, err := status.NewChecker(ctx, cfg)
	if err != nil {
		log.Printf("Error creating checker: %v", err)
		return nil, err
	}

	st, err := checker.GetStatus(ctx)
	if err != nil {
		log.Printf("Error getting status: %v", err)
		return nil, err
	}

	if st.Status == "grace_period" {
		log.Printf("Cluster in grace period: %s", st.Reason)
		return &Response{Status: "grace_period", Reason: st.Reason}, nil
	}

	isIdle := st.Status == "idle"

	if isIdle {
		log.Printf("Cluster is idle: %s", st.Reason)

		if !enableAutoDestroy {
			log.Printf("DRY RUN: Would trigger destroy, but enable_auto_destroy=false")
			return &Response{Status: "dry_run", Idle: true, Reason: st.Reason}, nil
		}

		// Invoke destroy Lambda
		log.Printf("Invoking %s...", destroyFunction)
		awsCfg, err := config.LoadDefaultConfig(ctx)
		if err != nil {
			return nil, err
		}

		lambdaClient := lambdasvc.NewFromConfig(awsCfg)
		_, err = lambdaClient.Invoke(ctx, &lambdasvc.InvokeInput{
			FunctionName:   &destroyFunction,
			InvocationType: "Event", // Async
		})
		if err != nil {
			log.Printf("Error invoking destroy: %v", err)
			return nil, err
		}

		return &Response{Status: "destroy_triggered", Reason: st.Reason}, nil
	}

	log.Printf("Cluster is active: %s", st.Reason)
	return &Response{Status: "active", Reason: st.Reason}, nil
}

func main() {
	lambda.Start(handler)
}
