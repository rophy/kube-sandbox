package terraform

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const (
	WorkDir         = "/tmp/workspace"
	TerraformDir    = "terraform/cluster"
	ProviderDir     = "/opt/terraform-providers"
	InitTimeout     = 5 * time.Minute
	ActionTimeout   = 10 * time.Minute
)

type Result struct {
	Success bool
	Output  string
}

// Run clones the repo and executes a terraform action (apply or destroy)
func Run(action, githubRepoURL, tfStateBucket string, generateSSHKey bool) Result {
	// Clean up any previous run
	os.RemoveAll(WorkDir)

	// Clone repo
	log.Printf("Cloning %s...", githubRepoURL)
	if err := runCommand(WorkDir, nil, "git", "clone", "--depth=1", githubRepoURL, WorkDir); err != nil {
		return Result{false, fmt.Sprintf("Clone failed: %v", err)}
	}

	terraformDir := filepath.Join(WorkDir, TerraformDir)
	sshDir := filepath.Join(WorkDir, ".ssh")

	// Create SSH directory and key
	if err := os.MkdirAll(sshDir, 0700); err != nil {
		return Result{false, fmt.Sprintf("Failed to create SSH dir: %v", err)}
	}

	if generateSSHKey {
		// Generate real SSH key for apply
		log.Println("Generating SSH key...")
		sshKey := filepath.Join(sshDir, "id_rsa")
		if err := runCommand("", nil, "ssh-keygen", "-t", "rsa", "-b", "4096", "-f", sshKey, "-N", "", "-C", "kube-sandbox"); err != nil {
			return Result{false, fmt.Sprintf("SSH keygen failed: %v", err)}
		}
	} else {
		// Create dummy key for destroy (just needs to satisfy file() in terraform)
		pubKey := filepath.Join(sshDir, "id_rsa.pub")
		if err := os.WriteFile(pubKey, []byte("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC dummy-key\n"), 0644); err != nil {
			return Result{false, fmt.Sprintf("Failed to create dummy key: %v", err)}
		}
	}

	// Create backend.tfvars
	backendTfvars := filepath.Join(terraformDir, "backend.tfvars")
	if err := os.WriteFile(backendTfvars, []byte(fmt.Sprintf("bucket = \"%s\"\n", tfStateBucket)), 0644); err != nil {
		return Result{false, fmt.Sprintf("Failed to create backend.tfvars: %v", err)}
	}

	env := []string{
		"TF_INPUT=0",
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + os.Getenv("HOME"),
	}
	// Add AWS credentials from environment
	for _, key := range []string{"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_REGION", "AWS_DEFAULT_REGION"} {
		if v := os.Getenv(key); v != "" {
			env = append(env, key+"="+v)
		}
	}

	// Run terraform init
	log.Println("Running terraform init...")
	initArgs := []string{
		"init",
		"-backend-config=backend.tfvars",
		"-no-color",
	}
	// Use pre-cached providers if available
	if _, err := os.Stat(ProviderDir); err == nil {
		initArgs = append(initArgs, "-plugin-dir="+ProviderDir)
	}

	if err := runCommandWithTimeout(terraformDir, env, InitTimeout, "terraform", initArgs...); err != nil {
		return Result{false, fmt.Sprintf("Init failed: %v", err)}
	}
	log.Println("Terraform init completed")

	// Run terraform action
	log.Printf("Running terraform %s...", action)
	if err := runCommandWithTimeout(terraformDir, env, ActionTimeout, "terraform", action, "-auto-approve", "-no-color"); err != nil {
		return Result{false, fmt.Sprintf("Terraform %s failed: %v", action, err)}
	}

	return Result{true, fmt.Sprintf("Terraform %s completed successfully", action)}
}

func runCommand(dir string, env []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	if len(env) > 0 {
		cmd.Env = env
	}

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%v: %s", err, stderr.String())
	}
	return nil
}

func runCommandWithTimeout(dir string, env []string, timeout time.Duration, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	if len(env) > 0 {
		cmd.Env = env
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	done := make(chan error, 1)
	go func() {
		done <- cmd.Run()
	}()

	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("%v\nstdout: %s\nstderr: %s", err, stdout.String(), stderr.String())
		}
		log.Printf("Output: %s", stdout.String())
		return nil
	case <-time.After(timeout):
		cmd.Process.Kill()
		return fmt.Errorf("command timed out after %v", timeout)
	}
}
