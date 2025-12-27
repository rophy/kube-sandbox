FROM node:20

ARG TZ=UTC
ENV TZ="$TZ"

# Tool versions
ARG TERRAFORM_VERSION=1.14.3
ARG HELM_VERSION=3.16.3
ARG SKAFFOLD_VERSION=2.14.0

# Install packages and tools
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
    # Docker CLI
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    # AWS CLI
    && ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "amd64" ]; then AWSARCH="x86_64"; else AWSARCH="aarch64"; fi \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSARCH}.zip" -o "awscliv2.zip" \
    && unzip -q awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip \
    # Terraform
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" -o terraform.zip \
    && unzip -q terraform.zip -d /usr/local/bin && rm terraform.zip \
    # kubectl
    && curl -fsSL "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    # Helm
    && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xzf - \
    && mv linux-${ARCH}/helm /usr/local/bin/helm && rm -rf linux-${ARCH} \
    # Skaffold
    && curl -fsSL "https://storage.googleapis.com/skaffold/releases/v${SKAFFOLD_VERSION}/skaffold-linux-${ARCH}" -o /usr/local/bin/skaffold \
    && chmod +x /usr/local/bin/skaffold

# Install Claude and Happy Coder
RUN npm install -g @anthropic-ai/claude-code@2.0.75 happy-coder

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share

ARG USERNAME=node

# User/group ID configuration (set at build time via .env)
ARG USER_UID=1000
ARG USER_GID=1000
ARG DOCKER_GID=999

# Update node user UID/GID to match host user, and set up docker group
RUN if [ "$USER_GID" != "1000" ]; then \
        groupmod -g $USER_GID node; \
    fi && \
    if [ "$USER_UID" != "1000" ]; then \
        usermod -u $USER_UID node; \
    fi && \
    # Create docker group with host's docker GID and add node user
    groupadd -g $DOCKER_GID docker 2>/dev/null || groupmod -g $DOCKER_GID docker 2>/dev/null || true && \
    usermod -aG docker node && \
    # Fix ownership of node's home directory
    chown -R node:node /home/node /usr/local/share/npm-global

# Set environment variables
ENV DEV_CONTAINER=true

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

# Grant passwordless sudo to node user
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Set up non-root user
USER node

# Setup dev container env
RUN echo 'alias claude="claude --dangerously-skip-permissions"' >> /home/node/.bashrc && \
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
