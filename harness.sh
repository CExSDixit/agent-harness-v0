#!/bin/bash
set -euo pipefail

# Agent Harness v0 — Parameterized spawn script
# Launches sandboxed AI coding agents in Docker containers
#
# Usage:
#   ./harness.sh plan    --project <path> --repos <repo:mode> ... --agent <agent>
#   ./harness.sh dev     --project <path> --repos <repo:mode> ... --agent <agent> --spec <path> [--parallel]
#   ./harness.sh review  --project <path> --repos <repo:mode> ... --agent <agent> --branches <b1,b2,...>
#
# Examples:
#   ./harness.sh plan --project caseiq/projects/ai-cockpit --repos ~/git/lextegrity/ai-cockpit:ro --agent claude-code
#   ./harness.sh dev --project caseiq/projects/ai-cockpit --repos ~/git/lextegrity/ai-cockpit:rw --agent claude-code --spec /path/to/Q-50-spec.md
#   ./harness.sh review --project caseiq/projects/ai-cockpit --repos ~/git/lextegrity/ai-cockpit:ro --agent claude-code --branches feat/q50-thing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="agent-harness:latest"
COOKBOOKS_PATH="${COOKBOOKS_PATH:-$HOME/git/cookbooks}"

# Defaults
PHASE=""
PROJECT=""
AGENT="claude-code"
NETWORK_PROFILE=""
SSH_KEY="${HARNESS_SSH_KEY:-}"
SPEC=""
BRANCHES=""
PARALLEL=false
REPOS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  cat <<'EOF'
Agent Harness v0 — Sandboxed AI coding agent launcher

USAGE:
  harness.sh <phase> [options]

PHASES:
  plan      Write specs and create tickets (repos: read-only, cookbooks: read-write)
  dev       Implement from a spec (repos: read-write, cookbooks: read-write)
  review    Adversarial review of branches (repos: read-only, cookbooks: read-write)

OPTIONS:
  --project <path>         Cookbooks project path (e.g., caseiq/projects/ai-cockpit)
  --repos <path:mode>      Repository to mount. Mode is rw or ro. Repeatable.
  --agent <name>           Agent to use: claude-code (default) or codex
  --network-profile <name> Network profile: default, plan, python-dev, node-dev, review-only
  --ssh-key <path>         SSH deploy key to mount (read-only)
  --spec <path>            Spec file path (dev phase)
  --branches <b1,b2,...>   Branches to review (review phase)
  --parallel               Enable parallel worktree execution (dev phase)
  --name <name>            Container name (default: harness-<phase>-<timestamp>)

ENVIRONMENT:
  COOKBOOKS_PATH           Path to cookbooks repo (default: ~/git/cookbooks)
  HARNESS_SSH_KEY          Default SSH key path
  ANTHROPIC_API_KEY        Claude Code API key
  OPENAI_API_KEY           Codex API key
EOF
  exit 1
}

die() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info() { echo -e "${GREEN}[harness]${NC} $*"; }
warn() { echo -e "${YELLOW}[harness]${NC} $*"; }

# Parse arguments
[[ $# -eq 0 ]] && usage
PHASE="$1"; shift

case "$PHASE" in
  plan|dev|review) ;;
  -h|--help|help) usage ;;
  *) die "Unknown phase: $PHASE. Use plan, dev, or review." ;;
esac

CONTAINER_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT="$2"; shift 2 ;;
    --repos)      REPOS+=("$2"); shift 2 ;;
    --agent)      AGENT="$2"; shift 2 ;;
    --network-profile) NETWORK_PROFILE="$2"; shift 2 ;;
    --ssh-key)    SSH_KEY="$2"; shift 2 ;;
    --spec)       SPEC="$2"; shift 2 ;;
    --branches)   BRANCHES="$2"; shift 2 ;;
    --parallel)   PARALLEL=true; shift ;;
    --name)       CONTAINER_NAME="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            die "Unknown option: $1" ;;
  esac
done

# Validation
[[ -z "$PROJECT" ]] && die "--project is required"
[[ ${#REPOS[@]} -eq 0 ]] && die "At least one --repos is required"
[[ "$PHASE" == "dev" && -z "$SPEC" ]] && die "--spec is required for dev phase"
[[ "$PHASE" == "review" && -z "$BRANCHES" ]] && die "--branches is required for review phase"

# Default network profile per phase
if [[ -z "$NETWORK_PROFILE" ]]; then
  case "$PHASE" in
    plan)   NETWORK_PROFILE="plan" ;;
    dev)    NETWORK_PROFILE="python-dev" ;;
    review) NETWORK_PROFILE="review-only" ;;
  esac
fi

# Default container name
if [[ -z "$CONTAINER_NAME" ]]; then
  CONTAINER_NAME="harness-${PHASE}-$(date +%s)"
fi

# Validate image exists
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  die "Image '$IMAGE_NAME' not found. Build it first: docker build -t $IMAGE_NAME ."
fi

# --- Create per-agent isolated config ---
AGENT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/harness-agent-XXXXXX")
info "Agent config dir: $AGENT_TMPDIR"

# Seed credentials based on agent type
if [[ "$AGENT" == "claude-code" ]]; then
  mkdir -p "$AGENT_TMPDIR/.claude"
  # Copy credentials only (not sessions/memory)
  [[ -f "$HOME/.claude.json" ]] && cp "$HOME/.claude.json" "$AGENT_TMPDIR/.claude.json"
  [[ -f "$HOME/.claude/credentials.json" ]] && cp "$HOME/.claude/credentials.json" "$AGENT_TMPDIR/.claude/credentials.json"
  [[ -f "$HOME/.claude/settings.json" ]] && cp "$HOME/.claude/settings.json" "$AGENT_TMPDIR/.claude/settings.json"
elif [[ "$AGENT" == "codex" ]]; then
  mkdir -p "$AGENT_TMPDIR/.codex"
  [[ -f "$HOME/.codex/auth.json" ]] && cp "$HOME/.codex/auth.json" "$AGENT_TMPDIR/.codex/auth.json"
  [[ -f "$HOME/.codex/config.toml" ]] && cp "$HOME/.codex/config.toml" "$AGENT_TMPDIR/.codex/config.toml"
else
  die "Unknown agent: $AGENT. Use claude-code or codex."
fi

# --- Build docker run arguments ---
DOCKER_ARGS=(
  "run"
  "--rm"
  "-it"
  "--name" "$CONTAINER_NAME"
  "--cap-add=NET_ADMIN"
  "--cap-add=NET_RAW"
  "-e" "HARNESS_ROLE=$PHASE"
  "-e" "HARNESS_NETWORK_PROFILE=$NETWORK_PROFILE"
  "-e" "HARNESS_PROJECT=$PROJECT"
  "-e" "HARNESS_AGENT=$AGENT"
)

# API keys via env
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && DOCKER_ARGS+=("-e" "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[[ -n "${OPENAI_API_KEY:-}" ]] && DOCKER_ARGS+=("-e" "OPENAI_API_KEY=$OPENAI_API_KEY")

# Agent config mounts
if [[ "$AGENT" == "claude-code" ]]; then
  DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.claude:/home/agent/.claude:rw")
  [[ -f "$AGENT_TMPDIR/.claude.json" ]] && DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.claude.json:/home/agent/.claude.json:ro")
elif [[ "$AGENT" == "codex" ]]; then
  DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.codex:/home/agent/.codex:rw")
fi

# SSH key mount
if [[ -n "$SSH_KEY" ]]; then
  [[ -f "$SSH_KEY" ]] || die "SSH key not found: $SSH_KEY"
  DOCKER_ARGS+=("-v" "$SSH_KEY:/home/agent/.ssh/id_ed25519:ro")
  # Mount known_hosts if it exists alongside the key
  SSH_DIR=$(dirname "$SSH_KEY")
  [[ -f "$SSH_DIR/known_hosts" ]] && DOCKER_ARGS+=("-v" "$SSH_DIR/known_hosts:/home/agent/.ssh/known_hosts:ro")
fi

# Cookbooks mount (always read-write — all phases write to it)
DOCKER_ARGS+=("-v" "$COOKBOOKS_PATH:/cookbooks:rw")

# Repo mounts
for repo_spec in "${REPOS[@]}"; do
  repo_path="${repo_spec%%:*}"
  repo_mode="${repo_spec##*:}"

  # Expand ~ if present
  repo_path="${repo_path/#\~/$HOME}"

  [[ -d "$repo_path" ]] || die "Repository not found: $repo_path"

  # Override mode based on phase for safety
  case "$PHASE" in
    plan)   repo_mode="ro" ;;   # Plan never writes to repos
    review) repo_mode="ro" ;;   # Review never writes to repos
    dev)    ;;                   # Dev respects the provided mode
  esac

  repo_name=$(basename "$repo_path")
  DOCKER_ARGS+=("-v" "$repo_path:/repos/$repo_name:$repo_mode")
done

# Phase-specific environment
if [[ "$PHASE" == "dev" ]]; then
  DOCKER_ARGS+=("-e" "HARNESS_SPEC=$SPEC")
  [[ "$PARALLEL" == "true" ]] && DOCKER_ARGS+=("-e" "HARNESS_PARALLEL=true")
fi

if [[ "$PHASE" == "review" ]]; then
  DOCKER_ARGS+=("-e" "HARNESS_BRANCHES=$BRANCHES")
fi

# Image and command
DOCKER_ARGS+=("$IMAGE_NAME")

# --- Launch ---
info "Phase:    $PHASE"
info "Project:  $PROJECT"
info "Agent:    $AGENT"
info "Network:  $NETWORK_PROFILE"
info "Repos:    ${REPOS[*]}"
[[ -n "$SPEC" ]] && info "Spec:     $SPEC"
[[ -n "$BRANCHES" ]] && info "Branches: $BRANCHES"
[[ "$PARALLEL" == "true" ]] && info "Parallel: enabled"
info "Container: $CONTAINER_NAME"
echo ""
info "Launching container..."
info "To allow a domain at runtime: docker exec $CONTAINER_NAME allow-domain <domain>"
echo ""

docker "${DOCKER_ARGS[@]}"

# Cleanup
info "Container exited. Cleaning up agent config dir..."
rm -rf "$AGENT_TMPDIR"
info "Done."
