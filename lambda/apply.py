"""
Apply the cluster using terraform apply.
Note: For full functionality, SSH key must exist in the repo or be generated.
"""
import os
import subprocess
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

WORK_DIR = '/tmp/workspace'


def handler(event, context):
    """
    Clone repo and run terraform apply on cluster.
    """
    github_repo_url = os.environ['GITHUB_REPO_URL']
    tf_state_bucket = os.environ['TF_STATE_BUCKET']

    logger.info("Starting cluster apply...")

    success, output = run_terraform('apply', github_repo_url, tf_state_bucket)

    if success:
        logger.info("Terraform apply completed successfully")
        return {'status': 'applied', 'output': output[-1000:]}
    else:
        logger.error(f"Terraform apply failed: {output[-2000:]}")
        return {'status': 'apply_failed', 'error': output[-2000:]}


def run_terraform(action, github_repo_url, tf_state_bucket):
    """
    Clone repo and run terraform action on cluster/ directory.
    """
    try:
        # Clean up any previous run
        subprocess.run(['rm', '-rf', WORK_DIR], capture_output=True)

        # Clone repo
        logger.info(f"Cloning {github_repo_url}...")
        subprocess.run(
            ['git', 'clone', '--depth=1', github_repo_url, WORK_DIR],
            check=True,
            capture_output=True,
            text=True
        )

        terraform_dir = os.path.join(WORK_DIR, 'terraform', 'cluster')

        # Generate SSH key for new cluster
        ssh_dir = os.path.join(WORK_DIR, '.ssh')
        os.makedirs(ssh_dir, exist_ok=True)
        ssh_key = os.path.join(ssh_dir, 'id_rsa')

        logger.info("Generating SSH key...")
        subprocess.run(
            ['ssh-keygen', '-t', 'rsa', '-b', '4096', '-f', ssh_key, '-N', '', '-C', 'kube-sandbox'],
            check=True,
            capture_output=True,
            text=True
        )

        # Create backend.tfvars
        backend_tfvars = os.path.join(terraform_dir, 'backend.tfvars')
        with open(backend_tfvars, 'w') as f:
            f.write(f'bucket = "{tf_state_bucket}"\n')

        env = os.environ.copy()
        env['TF_INPUT'] = '0'

        # Run terraform init
        logger.info("Running terraform init...")
        init_result = subprocess.run(
            [
                'terraform', 'init',
                '-backend-config=backend.tfvars',
                '-plugin-dir=/opt/terraform-providers',
                '-no-color'
            ],
            cwd=terraform_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=300
        )

        if init_result.returncode != 0:
            return False, f"Init failed:\n{init_result.stdout}\n{init_result.stderr}"

        logger.info("Terraform init completed")

        # Run terraform action
        logger.info(f"Running terraform {action}...")
        action_result = subprocess.run(
            ['terraform', action, '-auto-approve', '-no-color'],
            cwd=terraform_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=600
        )

        output = f"{action_result.stdout}\n{action_result.stderr}"

        if action_result.returncode != 0:
            return False, output

        return True, output

    except subprocess.TimeoutExpired as e:
        return False, f"Terraform operation timed out: {e}"
    except Exception as e:
        return False, f"Error: {e}"
