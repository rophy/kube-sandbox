# Terraform Lambda image for apply/destroy operations
#
# Single image handles both actions via TF_ACTION env var.
# Uses bash script instead of Go for simplicity.
#
# Build: docker build -f Dockerfile.tf -t kube-sandbox-tf .

ARG TERRAFORM_VERSION=1.14.3

# Stage 1: Download terraform providers
FROM hashicorp/terraform:1.14 AS provider-cache

WORKDIR /workspace

COPY terraform/cluster/*.tf ./terraform/cluster/

# Create minimal backend override to skip S3 backend during init
RUN printf 'terraform {\n  backend "local" {}\n}\n' > terraform/cluster/backend_override.tf

# Initialize to download providers
RUN cd terraform/cluster && terraform init -backend=false

# Copy providers to a known location
RUN cp -r terraform/cluster/.terraform/providers /providers

# Stage 2: Lambda runtime with terraform
FROM public.ecr.aws/lambda/provided:al2023

ARG TERRAFORM_VERSION

# Install terraform, git, and openssh
RUN dnf install -y unzip git openssh \
    && curl -sLo /tmp/terraform.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && dnf clean all

# Copy pre-cached providers
COPY --from=provider-cache /providers /opt/terraform-providers

# Copy shell script as Lambda bootstrap
COPY lambda/tf.sh /var/runtime/bootstrap
RUN chmod +x /var/runtime/bootstrap

# Override the default entrypoint to run our bootstrap directly
ENTRYPOINT ["/var/runtime/bootstrap"]
