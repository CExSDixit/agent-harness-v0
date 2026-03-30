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
#   ./harness.sh plan --project my-org/my-project --repos ~/git/my-app:ro --agent claude-code
#   ./harness.sh dev --project my-org/my-project --repos ~/git/my-app:rw --agent claude-code --spec /context/my-org/my-project/PROJ-1-feature.md
#   ./harness.sh review --project my-org/my-project --repos ~/git/my-app:ro --agent claude-code --branches feat/proj-1-feature

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="agent-harness:latest"

# Auto-source .env if it exists (won't override already-set vars)
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

COOKBOOKS_PATH="${COOKBOOKS_PATH:-}"

# Defaults
PHASE=""
PROJECT=""
AGENT="claude-code"
NETWORK_PROFILE=""
GITHUB_APP_PEM="${GITHUB_APP_PEM:-}"
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
  --project <path>         Context repo project path (e.g., my-org/my-project)
  --repos <path:mode>      Repository to mount. Mode is rw or ro. Repeatable.
  --agent <name>           Agent to use: claude-code (default) or codex
  --network-profile <name> Network profile: default, plan, python-dev, node-dev, review-only
  --spec <path>            Spec file path (dev phase)
  --branches <b1,b2,...>   Branches to review (review phase)
  --parallel               Enable parallel worktree execution (dev phase)
  --name <name>            Container name (default: harness-<phase>-<timestamp>)

ENVIRONMENT:
  COOKBOOKS_PATH                 Path to your context/notes repo (required)
  GITHUB_APP_ID                  GitHub App ID (for git push/pull and gh CLI)
  GITHUB_APP_INSTALLATION_ID     GitHub App Installation ID
  GITHUB_APP_PEM                 Path to GitHub App private key PEM file
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
    --spec)       SPEC="$2"; shift 2 ;;
    --branches)   BRANCHES="$2"; shift 2 ;;
    --parallel)   PARALLEL=true; shift ;;
    --name)       CONTAINER_NAME="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            die "Unknown option: $1" ;;
  esac
done

# Validation
[[ -z "$COOKBOOKS_PATH" ]] && die "COOKBOOKS_PATH environment variable is required. Set it to your context/notes repo path."
[[ ! -d "$COOKBOOKS_PATH" ]] && die "COOKBOOKS_PATH directory not found: $COOKBOOKS_PATH"
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

# --- Validate repo name uniqueness ---
SEEN_REPO_NAMES=""
for repo_spec in "${REPOS[@]}"; do
  repo_path="${repo_spec%%:*}"
  repo_path="${repo_path/#\~/$HOME}"
  rname=$(basename "$repo_path")
  if echo "$SEEN_REPO_NAMES" | grep -qx "$rname"; then
    die "Repo name collision: '$rname' would be mounted twice (/repos/$rname). Use repos with distinct directory names."
  fi
  SEEN_REPO_NAMES="$SEEN_REPO_NAMES
$rname"
done

# --- Create per-agent isolated config ---
AGENT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/harness-agent-XXXXXX")
trap 'rm -rf "$AGENT_TMPDIR" 2>/dev/null' EXIT
info "Agent config dir: $AGENT_TMPDIR"

# Seed credentials based on agent type
if [[ "$AGENT" == "claude-code" ]]; then
  mkdir -p "$AGENT_TMPDIR/.claude"
  # Copy config files (not sessions/memory)
  [[ -f "$HOME/.claude/credentials.json" ]] && cp "$HOME/.claude/credentials.json" "$AGENT_TMPDIR/.claude/credentials.json"
  [[ -f "$HOME/.claude/settings.json" ]] && cp "$HOME/.claude/settings.json" "$AGENT_TMPDIR/.claude/settings.json"
  # Sanitize .claude.json for container use:
  # - Rewrite localhost URLs to host.docker.internal (for host-side services like Plane)
  # - Remove MCP servers that require host hardware (trnscrb)
  # Build path mapping JSON: host paths → container paths
  # Cookbooks path → /cookbooks, each repo → /repos/<basename>
  PATH_MAP="{\"$(cd "$COOKBOOKS_PATH" && pwd -P)\": \"/cookbooks\""
  for repo_spec in "${REPOS[@]}"; do
    repo_path="${repo_spec%%:*}"
    repo_path="${repo_path/#\~/$HOME}"
    repo_real="$(cd "$repo_path" && pwd -P)"
    repo_name=$(basename "$repo_path")
    PATH_MAP="$PATH_MAP, \"$repo_real\": \"/repos/$repo_name\""
  done
  PATH_MAP="$PATH_MAP}"

  if [[ -f "$HOME/.claude.json" ]]; then
    python3 -c "
import json, sys, re

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except (json.JSONDecodeError, IOError) as e:
    print(f'[sanitize] ERROR: Failed to read {sys.argv[1]}: {e}', file=sys.stderr)
    sys.exit(1)
try:
    path_map = json.loads(sys.argv[3])
except json.JSONDecodeError as e:
    print(f'[sanitize] ERROR: Invalid path map JSON: {e}', file=sys.stderr)
    sys.exit(1)

def sanitize_mcp(servers):
    to_remove = []
    for name, cfg in servers.items():
        # Rewrite STDIO servers that need host hardware to HTTP/SSE transport
        # (they must be running on the host with network transport enabled)
        if name == 'trnscrb' and cfg.get('type', 'stdio') == 'stdio':
            servers[name] = {
                'type': 'sse',
                'url': 'http://host.docker.internal:8001/sse'
            }
            continue
        # Rewrite localhost to host.docker.internal in env vars and URLs
        if 'env' in cfg:
            for k, v in cfg['env'].items():
                if isinstance(v, str):
                    cfg['env'][k] = re.sub(r'localhost|127\.0\.0\.1', 'host.docker.internal', v)
        if 'url' in cfg and isinstance(cfg['url'], str):
            cfg['url'] = re.sub(r'localhost|127\.0\.0\.1', 'host.docker.internal', cfg['url'])
    for name in to_remove:
        del servers[name]

# Global mcpServers
if 'mcpServers' in d:
    sanitize_mcp(d['mcpServers'])

# Per-project mcpServers — remap project paths to container paths
if 'projects' in d:
    remapped = {}
    for proj, pcfg in d['projects'].items():
        # Find the container path for this project
        container_path = None
        for host_path, cont_path in path_map.items():
            if proj == host_path or proj.rstrip('/') == host_path.rstrip('/'):
                container_path = cont_path
                break
        new_key = container_path if container_path else proj
        if new_key in remapped:
            # Merge MCP servers if same container path
            existing = remapped[new_key].get('mcpServers', {})
            existing.update(pcfg.get('mcpServers', {}))
            remapped[new_key]['mcpServers'] = existing
        else:
            remapped[new_key] = pcfg
        if 'mcpServers' in remapped[new_key]:
            sanitize_mcp(remapped[new_key]['mcpServers'])
    d['projects'] = remapped

try:
    with open(sys.argv[2], 'w') as f:
        json.dump(d, f, indent=2)
except IOError as e:
    print(f'[sanitize] ERROR: Failed to write {sys.argv[2]}: {e}', file=sys.stderr)
    sys.exit(1)
" "$HOME/.claude.json" "$AGENT_TMPDIR/.claude.json" "$PATH_MAP" || die "Failed to sanitize .claude.json"
    info "Sanitized .claude.json (remapped paths, rewrote localhost, removed hardware-dependent MCP servers)"
  fi
elif [[ "$AGENT" == "codex" ]]; then
  mkdir -p "$AGENT_TMPDIR/.codex"
  # Copy auth tokens (read-write — Codex refreshes tokens in place)
  [[ -f "$HOME/.codex/auth.json" ]] && cp "$HOME/.codex/auth.json" "$AGENT_TMPDIR/.codex/auth.json"
  # Copy and sanitize config (rewrite localhost → host.docker.internal for MCP servers)
  if [[ -f "$HOME/.codex/config.toml" ]]; then
    # Sanitize: rewrite localhost, strip host-specific [projects.*] sections
    python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
# Rewrite localhost
content = re.sub(r'localhost|127\.0\.0\.1', 'host.docker.internal', content)
# Remove [projects.*] sections (host paths that don't exist in container)
content = re.sub(r'\[projects\.[^\]]*\]\n(?:[^\[]*\n)*', '', content)
with open(sys.argv[2], 'w') as f:
    f.write(content)
" "$HOME/.codex/config.toml" "$AGENT_TMPDIR/.codex/config.toml"
    info "Sanitized .codex/config.toml (rewrote localhost, stripped host project paths)"
  fi
  # Copy project-level codex configs from mounted repos
  for repo_spec in "${REPOS[@]}"; do
    repo_path="${repo_spec%%:*}"
    repo_path="${repo_path/#\~/$HOME}"
    repo_name=$(basename "$repo_path")
    if [[ -f "$repo_path/.codex/auth.json" ]]; then
      mkdir -p "$AGENT_TMPDIR/.codex/projects/$repo_name"
      cp "$repo_path/.codex/auth.json" "$AGENT_TMPDIR/.codex/projects/$repo_name/auth.json"
    fi
  done
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
  ${CLAUDE_CODE_OAUTH_TOKEN:+"-e" "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN"}
  ${OPENAI_API_KEY:+"-e" "OPENAI_API_KEY=$OPENAI_API_KEY"}
)

# Agent config mounts
if [[ "$AGENT" == "claude-code" ]]; then
  DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.claude:/home/agent/.claude:rw")
  [[ -f "$AGENT_TMPDIR/.claude.json" ]] && DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.claude.json:/home/agent/.claude.json:rw")
elif [[ "$AGENT" == "codex" ]]; then
  DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.codex:/home/agent/.codex:rw")
fi

# GitHub App credentials (for git HTTPS push/pull and gh CLI)
if [[ -n "${GITHUB_APP_ID:-}" && -n "${GITHUB_APP_INSTALLATION_ID:-}" && -n "$GITHUB_APP_PEM" ]]; then
  GITHUB_APP_PEM="${GITHUB_APP_PEM/#\~/$HOME}"
  [[ -f "$GITHUB_APP_PEM" ]] || die "GitHub App PEM not found: $GITHUB_APP_PEM"
  DOCKER_ARGS+=("-v" "$GITHUB_APP_PEM:/etc/harness/github-app.pem:ro")
  DOCKER_ARGS+=("-e" "GITHUB_APP_ID=$GITHUB_APP_ID")
  DOCKER_ARGS+=("-e" "GITHUB_APP_INSTALLATION_ID=$GITHUB_APP_INSTALLATION_ID")
  DOCKER_ARGS+=("-e" "GITHUB_APP_PEM_PATH=/etc/harness/github-app.pem")
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

# Image and command — start detached first so we can init firewall as root
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

# Step 1: Start container detached (keeps it alive via sleep)
info "Starting container..."
# Replace -it with -d, override CMD to keep container alive
DOCKER_ARGS_DETACHED=("${DOCKER_ARGS[@]}")
# Remove "-it" and add "-d", override command to sleep
DOCKER_DETACH_ARGS=(
  "run" "--rm" "-d"
  "--name" "$CONTAINER_NAME"
  "--cap-add=NET_ADMIN"
  "--cap-add=NET_RAW"
)
# Re-add all -e and -v flags from DOCKER_ARGS (skip run, --rm, -it, --name, --cap-add, image)
for ((i=0; i<${#DOCKER_ARGS[@]}; i++)); do
  case "${DOCKER_ARGS[$i]}" in
    run|--rm|-it|-d) continue ;;
    --name) ((i++)); continue ;;  # skip --name and its value
    --cap-add=*) continue ;;
    "$IMAGE_NAME") continue ;;
    *) DOCKER_DETACH_ARGS+=("${DOCKER_ARGS[$i]}") ;;
  esac
done
DOCKER_DETACH_ARGS+=("$IMAGE_NAME" "sleep" "infinity")

docker "${DOCKER_DETACH_ARGS[@]}" >/dev/null

# Step 2: Initialize firewall as root (agent user cannot do this)
info "Initializing firewall as root (profile: $NETWORK_PROFILE)..."
if ! docker exec -u root "$CONTAINER_NAME" /usr/local/bin/init-firewall.sh "$NETWORK_PROFILE"; then
  warn "FATAL: Firewall initialization failed. Stopping container."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -rf "$AGENT_TMPDIR"
  die "Cannot start without network isolation."
fi

# Step 3: Initialize GitHub App auth as root (if configured)
if docker exec "$CONTAINER_NAME" printenv GITHUB_APP_ID &>/dev/null; then
  info "Configuring GitHub App authentication..."
  if ! docker exec -u root "$CONTAINER_NAME" /usr/local/bin/github-auth.sh; then
    warn "GitHub App auth failed — git push/pull and gh CLI may not work"
  fi
fi

# Step 4: Attach interactive session as agent user
info "Attaching to container as agent user..."
info "To allow a domain at runtime: docker exec -u root $CONTAINER_NAME allow-domain <domain>"
info "To refresh GitHub token (after 1h): docker exec -u root $CONTAINER_NAME /usr/local/bin/github-auth.sh"
echo ""

docker exec -it -u agent "$CONTAINER_NAME" /usr/local/bin/entrypoint.sh zsh

# Cleanup
info "Session ended. Stopping container..."
docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
rm -rf "$AGENT_TMPDIR"
info "Done."
