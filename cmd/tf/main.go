package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/rophy/kube-sandbox/internal/terraform"
)

type Response struct {
	Status string `json:"status"`
	Output string `json:"output,omitempty"`
	Error  string `json:"error,omitempty"`
}

func handler(ctx context.Context) (*Response, error) {
	action := os.Getenv("TF_ACTION")
	if action != "apply" && action != "destroy" {
		return &Response{
			Status: "error",
			Error:  "TF_ACTION must be 'apply' or 'destroy'",
		}, nil
	}

	githubRepoURL := os.Getenv("GITHUB_REPO_URL")
	tfStateBucket := os.Getenv("TF_STATE_BUCKET")

	if githubRepoURL == "" || tfStateBucket == "" {
		return &Response{
			Status: "error",
			Error:  "GITHUB_REPO_URL and TF_STATE_BUCKET environment variables are required",
		}, nil
	}

	log.Printf("Starting cluster %s...", action)

	// Generate real SSH key for apply, dummy for destroy
	generateSSHKey := action == "apply"
	result := terraform.Run(action, githubRepoURL, tfStateBucket, generateSSHKey)

	if result.Success {
		log.Printf("Terraform %s completed successfully", action)
		return &Response{Status: fmt.Sprintf("%sed", action), Output: truncate(result.Output, 1000)}, nil
	}

	log.Printf("Terraform %s failed: %s", action, result.Output)
	return &Response{Status: fmt.Sprintf("%s_failed", action), Error: truncate(result.Output, 2000)}, nil
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[len(s)-maxLen:]
}

func main() {
	lambda.Start(handler)
}
