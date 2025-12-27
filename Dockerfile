FROM node:20

ARG TZ=UTC
ENV TZ="$TZ"

# Install basic development tools, AWS CLI, Terraform, kubectl, and tini
RUN apt-get update && apt-get install -y --no-install-recommends \
    less \
    git \
    procps \
    sudo \
    fzf \
    man-db \
    unzip \
    gnupg2 \
    jq \
    nano \
    vim \
    curl \
    wget \
    tini \
    python3 \
    python3-jinja2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then AWSARCH="x86_64"; else AWSARCH="aarch64"; fi && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSARCH}.zip" -o "awscliv2.zip" && \
    unzip -q awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# Install Terraform
ARG TERRAFORM_VERSION=1.14.3
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" -o terraform.zip && \
    unzip -q terraform.zip -d /usr/local/bin && \
    rm terraform.zip && \
    chmod +x /usr/local/bin/terraform

# Install kubectl
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install Helm
ARG HELM_VERSION=3.16.3
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xzf - && \
    mv linux-${ARCH}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH} && \
    chmod +x /usr/local/bin/helm

# Install Claude and Happy Coder
RUN npm install -g @anthropic-ai/claude-code@2.0.70 happy-coder

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share

ARG USERNAME=node

# Set environment variables
ENV DEV_CONTAINER=true
ENV KUBECONFIG=/workspace/kubeconfig.yaml

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude /home/node/.aws /home/node/.kube /home/node/.terraform.d/plugin-cache && \
    chown -R node:node /workspace /home/node/.claude /home/node/.aws /home/node/.kube /home/node/.terraform.d

WORKDIR /workspace

# Install git-delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER node

# Setup dev container env
RUN echo 'export KUBECONFIG=/workspace/kubeconfig.yaml' >> /home/node/.bashrc && \
    echo 'alias claude="claude --dangerously-skip-permissions"' >> /home/node/.bashrc && \
    echo 'alias happy="happy --dangerously-skip-permissions"' >> /home/node/.bashrc
#    npm install -g happy-coder

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to bash
ENV SHELL=/bin/bash

# Use tini as init system
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
