import os
import subprocess
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

WORK_DIR = '/tmp/workspace'


def handler(event, context):
    """
    Triggered by EC2 cronjob when idle detected.
    Clones repo and runs terraform destroy.
    """
    github_repo_url = os.environ['GITHUB_REPO_URL']
    tf_state_bucket = os.environ['TF_STATE_BUCKET']
    enable_auto_destroy = os.environ.get('ENABLE_AUTO_DESTROY', 'false').lower() == 'true'

    logger.info(f"Lambda invoked: enable_auto_destroy={enable_auto_destroy}")

    if not enable_auto_destroy:
        logger.warning("DRY RUN: Would trigger destroy, but enable_auto_destroy=false")
        return {'status': 'dry_run', 'message': 'Auto-destroy disabled'}

    logger.warning("Running terraform destroy...")
    success, output = run_terraform_destroy(github_repo_url, tf_state_bucket)

    if success:
        logger.warning("Terraform destroy completed successfully")
        return {'status': 'destroyed', 'output': output[-1000:]}
    else:
        logger.error(f"Terraform destroy failed: {output[-2000:]}")
        return {'status': 'destroy_failed', 'error': output[-2000:]}


def run_terraform_destroy(github_repo_url, tf_state_bucket):
    """
    Clone repo and run terraform destroy.
    """
    try:
        # Clone repo
        logger.info(f"Cloning {github_repo_url}...")
        subprocess.run(
            ['git', 'clone', '--depth=1', github_repo_url, WORK_DIR],
            check=True,
            capture_output=True,
            text=True
        )

        terraform_dir = os.path.join(WORK_DIR, 'terraform')

        # Create backend.tfvars
        backend_tfvars = os.path.join(terraform_dir, 'backend.tfvars')
        with open(backend_tfvars, 'w') as f:
            f.write(f'bucket = "{tf_state_bucket}"\n')

        # Set environment for terraform
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

        # Run terraform destroy
        logger.info("Running terraform destroy...")
        destroy_result = subprocess.run(
            ['terraform', 'destroy', '-auto-approve', '-no-color'],
            cwd=terraform_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=600
        )

        output = f"{destroy_result.stdout}\n{destroy_result.stderr}"

        if destroy_result.returncode != 0:
            return False, output

        return True, output

    except subprocess.TimeoutExpired as e:
        return False, f"Terraform operation timed out: {e}"
    except Exception as e:
        return False, f"Error: {e}"
