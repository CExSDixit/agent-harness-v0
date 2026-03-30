# Agent Harness v0
# Sandboxed execution environment for AI coding agents
# One image, multiple roles (plan/dev/review), multiple agents (claude-code/codex)
#
# Build:
#   docker build -t agent-harness:latest .
#
# Run:
#   Use harness.sh for parameterized launch, or manually:
#   docker run --cap-add=NET_ADMIN --cap-add=NET_RAW -it agent-harness:latest

FROM ubuntu:24.04

ARG TZ=UTC
ENV TZ="$TZ"
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# System packages: dev tools + network policy tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
  # Core
  git \
  curl \
  wget \
  sudo \
  ca-certificates \
  # Shell
  zsh \
  tmux \
  # Search tools
  ripgrep \
  fd-find \
  fzf \
  jq \
  # Build tools
  build-essential \
  # Editors
  nano \
  vim \
  # Network policy (iptables + ipset for allowlisting)
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  # Misc
  unzip \
  less \
  procps \
  man-db \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# git-delta for better diffs
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" -o /tmp/git-delta.deb && \
  dpkg -i /tmp/git-delta.deb && \
  rm /tmp/git-delta.deb

# Create agent user (non-root)
ARG USERNAME=agent
RUN useradd -m -s /bin/zsh "$USERNAME"
# No sudo access for the agent user. All privileged operations (firewall init,
# domain allow/deny) are performed by the operator via `docker exec -u root`.

# Create working directories
RUN mkdir -p /workspace /repos /cookbooks /specs /commandhistory && \
  touch /commandhistory/.zsh_history && \
  chown -R "$USERNAME":"$USERNAME" /workspace /repos /cookbooks /specs /commandhistory

# Copy firewall and helper scripts
COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY scripts/allow-domain /usr/local/bin/allow-domain
COPY scripts/deny-domain /usr/local/bin/deny-domain
COPY scripts/list-allowed /usr/local/bin/list-allowed
COPY profiles/ /etc/harness/profiles/
RUN chmod +x /usr/local/bin/init-firewall.sh \
  /usr/local/bin/allow-domain \
  /usr/local/bin/deny-domain \
  /usr/local/bin/list-allowed

# Firewall scripts are operator-only (run via `docker exec` from host as root).
# The agent user intentionally CANNOT modify network policies.
# init-firewall.sh runs as root via entrypoint before dropping to agent user.

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

WORKDIR /workspace

# Switch to non-root for tool installations
USER "$USERNAME"

ENV PATH="/home/${USERNAME}/.local/bin:$PATH"

# Install uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Python 3.13 via uv
RUN /home/"$USERNAME"/.local/bin/uv python install 3.13 --default

# Install fnm (Fast Node Manager) + Node 22
ARG NODE_VERSION=22
ENV FNM_DIR="/home/${USERNAME}/.fnm"
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell && \
  export PATH="$FNM_DIR:$PATH" && \
  eval "$(fnm env)" && \
  fnm install ${NODE_VERSION} && \
  fnm default ${NODE_VERSION}

# Install Claude Code
RUN export PATH="$FNM_DIR:$PATH" && \
  eval "$($FNM_DIR/fnm env)" && \
  npm install -g @anthropic-ai/claude-code@latest

# Install Codex CLI
RUN export PATH="$FNM_DIR:$PATH" && \
  eval "$($FNM_DIR/fnm env)" && \
  npm install -g @openai/codex@latest

# Environment
ENV FNM_DIR="/home/${USERNAME}/.fnm"
ENV HARNESS_ROLE="developer"
ENV HARNESS_NETWORK_PROFILE="default"

# Persistent history across rebuilds (when volume-mounted)
ENV HISTFILE=/commandhistory/.zsh_history
ENV HISTSIZE=200000
ENV SAVEHIST=200000

# Entrypoint: runs as agent user. Firewall is initialized separately.
# Firewall init happens via harness.sh calling `docker exec -u root` BEFORE
# the agent session starts. The agent process never has root access.
USER ${USERNAME}

COPY --chown=${USERNAME}:${USERNAME} scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh"]
