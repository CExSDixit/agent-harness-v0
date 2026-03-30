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

# ── System packages ──────────────────────────────────────────────────────────
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    git curl wget ca-certificates \
    zsh tmux \
    ripgrep fd-find fzf jq \
    build-essential \
    nano vim \
    iptables ipset iproute2 dnsutils \
    unzip less procps man-db \
  && \
  # GitHub CLI (needs curl, so must come after base install)
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list && \
  apt-get update && apt-get install -y --no-install-recommends gh && \
  # git-delta
  ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/dandavison/delta/releases/download/0.18.2/git-delta_0.18.2_${ARCH}.deb" \
    -o /tmp/git-delta.deb && \
  dpkg -i /tmp/git-delta.deb && rm /tmp/git-delta.deb && \
  # Cleanup
  apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Agent user (no sudo) ────────────────────────────────────────────────────
ARG USERNAME=agent
RUN useradd -m -s /bin/zsh "$USERNAME"

# ── Working directories ─────────────────────────────────────────────────────
RUN mkdir -p /workspace /repos /cookbooks /specs /commandhistory && \
  touch /commandhistory/.zsh_history && \
  chown -R "$USERNAME":"$USERNAME" /workspace /repos /cookbooks /specs /commandhistory

# ── Scripts and profiles ─────────────────────────────────────────────────────
COPY scripts/init-firewall.sh scripts/github-auth.sh \
     scripts/allow-domain scripts/deny-domain scripts/list-allowed \
     /usr/local/bin/
COPY profiles/ /etc/harness/profiles/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/github-auth.sh \
  /usr/local/bin/allow-domain /usr/local/bin/deny-domain /usr/local/bin/list-allowed

# ── Environment ──────────────────────────────────────────────────────────────
ENV DEVCONTAINER=true \
    SHELL=/bin/zsh \
    EDITOR=nano \
    VISUAL=nano \
    HARNESS_ROLE=review \
    HARNESS_NETWORK_PROFILE=review-only \
    HISTFILE=/commandhistory/.zsh_history \
    HISTSIZE=200000 \
    SAVEHIST=200000

WORKDIR /workspace

# ── User-level tool installations (single layer) ────────────────────────────
USER "$USERNAME"

ARG NODE_VERSION=22
ENV FNM_DIR="/home/${USERNAME}/.fnm" \
    PATH="/home/${USERNAME}/.fnm:/home/${USERNAME}/.local/bin:$PATH"

RUN \
  # uv (Python package manager) + Python 3.13
  curl -LsSf https://astral.sh/uv/install.sh | sh && \
  uv python install 3.13 --default && \
  # fnm (Node version manager) + Node
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell && \
  eval "$($FNM_DIR/fnm env)" && \
  fnm install ${NODE_VERSION} && \
  fnm default ${NODE_VERSION} && \
  # Claude Code + Codex CLI
  eval "$($FNM_DIR/fnm env)" && \
  npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest

# ── Shell config ─────────────────────────────────────────────────────────────
COPY --chown=${USERNAME}:${USERNAME} scripts/zshenv /home/${USERNAME}/.zshenv
COPY --chown=${USERNAME}:${USERNAME} scripts/zshrc /home/${USERNAME}/.zshrc

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY --chown=${USERNAME}:${USERNAME} scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh"]
