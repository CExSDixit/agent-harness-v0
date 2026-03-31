#!/bin/bash
set -euo pipefail

# Agent Harness v0 — Parameterized spawn script
# Launches sandboxed AI coding agents in Docker containers
#
# Usage:
#   ./harness.sh plan    --project <path> --repos <repo:mode> ...
#   ./harness.sh dev     --project <path> --repos <repo:mode> ... [--agent <agent>] [--spec <path>]
#   ./harness.sh review  --project <path> --repos <repo:mode> ... --branches <b1,b2,...> [--agent <agent>] [--review-spec <stage|main>]
#
# Examples:
#   ./harness.sh plan --project my-org/my-project --repos ~/git/my-app:ro
#   ./harness.sh dev --project my-org/my-project --repos ~/git/my-app:rw --agent codex --spec Q-47-mcp-validation-handoff.md
#   ./harness.sh review --project my-org/my-project --repos ~/git/my-app:ro --branches feat/proj-1-feature

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="agent-harness:latest"

# Auto-source .env if it exists (won't override already-set vars)
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

COOKBOOKS_PATH="${COOKBOOKS_PATH:-}"

# Defaults
PHASE=""
PROJECT=""
AGENT=""
NETWORK_PROFILE=""
GITHUB_APP_PEM="${GITHUB_APP_PEM:-}"
SPEC=""
BRANCHES=""
REVIEW_SPEC=""
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
  --project <name|path>    Project name or path (e.g., ai-cockpit or caseiq/projects/ai-cockpit)
  --repos <path:mode>      Repository to mount. Mode is rw or ro. Repeatable.
  --agent <name>           Agent: claude-code (or claude), codex. See defaults below.
  --network-profile <name> Network profile: default, plan, python-dev, node-dev, review-only
  --spec <path|filename>   Dev: spec file (path, relative path, or filename). Optional.
  --branches <b1,b2,...>   Branches to review (review phase, required)
  --base <stage|main>      Review comparison base (default: stage)
  --name <name>            Container name (default: harness-<phase>-<timestamp>)
  --dry-run                Print resolved config and exit (no Docker)

AGENT DEFAULTS:
  plan    → claude-code (auto-launches with repo context prompt)
  dev     → claude-code if --spec given, otherwise shell (both agents available)
  review  → codex (auto-launches with review coordinator prompt)

  Both agents are always authenticated. Override with --agent.

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

# Expand repo spec to absolute path (strips :mode, expands ~)
repo_path_from_spec() { local p="${1%%:*}"; echo "${p/#\~/$HOME}"; }
repo_mode_from_spec() { echo "${1##*:}"; }

# Parse arguments
[[ $# -eq 0 ]] && usage
PHASE="$1"; shift

case "$PHASE" in
  plan|dev|review) ;;
  -h|--help|help) usage ;;
  *) die "Unknown phase: $PHASE. Use plan, dev, or review." ;;
esac

CONTAINER_NAME=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT="$2"; shift 2 ;;
    --repos)      REPOS+=("$2"); shift 2 ;;
    --agent)      AGENT="$2"; shift 2 ;;
    --network-profile) NETWORK_PROFILE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --spec)       SPEC="$2"; shift 2 ;;
    --branches)   BRANCHES="$2"; shift 2 ;;
    --base)       REVIEW_SPEC="$2"; shift 2 ;;
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
[[ "$PHASE" == "review" && -z "$BRANCHES" ]] && die "--branches is required for review phase"

# Resolve project name to full path within cookbooks
if [[ "$PROJECT" != */* ]]; then
  # Short name — find matching project directories
  MATCHES=$(find "$COOKBOOKS_PATH" -type d -path "*/projects/$PROJECT" 2>/dev/null)
  MATCH_COUNT=$(echo "$MATCHES" | grep -c . 2>/dev/null || true)
  if [[ "$MATCH_COUNT" -eq 0 ]]; then
    die "Project '$PROJECT' not found in $COOKBOOKS_PATH"
  elif [[ "$MATCH_COUNT" -gt 1 ]]; then
    echo -e "${RED}ERROR:${NC} Multiple projects match '$PROJECT':" >&2
    echo "$MATCHES" | while read -r m; do echo "  ${m#$COOKBOOKS_PATH/}" >&2; done
    die "Specify the full path (e.g., --project $(echo "$MATCHES" | head -1 | sed "s|$COOKBOOKS_PATH/||"))"
  fi
  PROJECT="${MATCHES#$COOKBOOKS_PATH/}"
  info "Resolved project: $PROJECT"
fi

# Normalize agent name (accept shorthand)
case "$AGENT" in
  claude) AGENT="claude-code" ;;
  "") ;;  # empty is OK, defaults applied below
  claude-code|codex) ;;  # valid
  *) die "Unknown agent: $AGENT. Use claude-code (or claude) or codex." ;;
esac

# Default agent per phase
if [[ -z "$AGENT" ]]; then
  case "$PHASE" in
    plan)   AGENT="claude-code" ;;  # Plan always launches with context prompt
    dev)    [[ -n "$SPEC" ]] && AGENT="claude-code" ;;  # Dev+spec defaults to claude
    review) AGENT="codex" ;;  # Review defaults to codex
  esac
fi

# Resolve dev spec to full container path
if [[ "$PHASE" == "dev" && -n "$SPEC" ]]; then
  if [[ "$SPEC" != /* ]]; then
    # Search within the resolved project directory first, then all of cookbooks
    PROJECT_DIR="$COOKBOOKS_PATH/$PROJECT"
    RESOLVED=$(find "$PROJECT_DIR" -path "*/$SPEC" -type f 2>/dev/null | head -1)
    [[ -z "$RESOLVED" ]] && RESOLVED=$(find "$PROJECT_DIR" -name "$(basename "$SPEC")" -type f 2>/dev/null | head -1)
    [[ -z "$RESOLVED" ]] && RESOLVED=$(find "$COOKBOOKS_PATH" -path "*/$SPEC" -type f 2>/dev/null | head -1)
    [[ -z "$RESOLVED" ]] && RESOLVED=$(find "$COOKBOOKS_PATH" -name "$(basename "$SPEC")" -type f 2>/dev/null | head -1)
    [[ -z "$RESOLVED" ]] && die "Spec file not found: $SPEC (searched $PROJECT_DIR and $COOKBOOKS_PATH)"
    SPEC="/cookbooks/${RESOLVED#$COOKBOOKS_PATH/}"
    info "Resolved spec: $SPEC"
  fi
fi

# Default and validate review base
if [[ "$PHASE" == "review" ]]; then
  REVIEW_SPEC="${REVIEW_SPEC:-stage}"
  case "$REVIEW_SPEC" in
    stage|main) ;;
    *) die "Unknown review base: $REVIEW_SPEC. Use stage or main." ;;
  esac
fi

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
  repo_path="$(repo_path_from_spec "$repo_spec")"
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

# --- Dry-run: print resolved config and exit ---
if [[ "$DRY_RUN" == "true" ]]; then
  echo "PHASE=$PHASE"
  echo "AGENT=${AGENT:-}"
  echo "SPEC=$SPEC"
  echo "REVIEW_SPEC=${REVIEW_SPEC:-}"
  echo "NETWORK=$NETWORK_PROFILE"
  echo "PROJECT=$PROJECT"
  echo "REPOS=${REPOS[*]}"
  exit 0
fi

# --- Seed credentials for BOTH agents (both always available in container) ---

# Claude Code credentials
mkdir -p "$AGENT_TMPDIR/.claude"
[[ -f "$HOME/.claude/credentials.json" ]] && cp "$HOME/.claude/credentials.json" "$AGENT_TMPDIR/.claude/credentials.json"
[[ -f "$HOME/.claude/settings.json" ]] && cp "$HOME/.claude/settings.json" "$AGENT_TMPDIR/.claude/settings.json"

# Build path mapping JSON for .claude.json sanitizer
PATH_MAP="{\"$(cd "$COOKBOOKS_PATH" && pwd -P)\": \"/cookbooks\""
for repo_spec in "${REPOS[@]}"; do
  repo_path="$(repo_path_from_spec "$repo_spec")"
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
        if name == 'trnscrb' and cfg.get('type', 'stdio') == 'stdio':
            servers[name] = {
                'type': 'sse',
                'url': 'http://host.docker.internal:8001/sse'
            }
            continue
        if 'env' in cfg:
            for k, v in cfg['env'].items():
                if isinstance(v, str):
                    cfg['env'][k] = re.sub(r'localhost|127\.0\.0\.1', 'host.docker.internal', v)
        if 'url' in cfg and isinstance(cfg['url'], str):
            cfg['url'] = re.sub(r'localhost|127\.0\.0\.1', 'host.docker.internal', cfg['url'])
    for name in to_remove:
        del servers[name]

if 'mcpServers' in d:
    sanitize_mcp(d['mcpServers'])

if 'projects' in d:
    remapped = {}
    for proj, pcfg in d['projects'].items():
        container_path = None
        for host_path, cont_path in path_map.items():
            if proj == host_path or proj.rstrip('/') == host_path.rstrip('/'):
                container_path = cont_path
                break
        new_key = container_path if container_path else proj
        if new_key in remapped:
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
  info "Sanitized .claude.json"
fi

# Codex credentials
mkdir -p "$AGENT_TMPDIR/.codex"
[[ -f "$HOME/.codex/auth.json" ]] && cp "$HOME/.codex/auth.json" "$AGENT_TMPDIR/.codex/auth.json"
[[ -f "$HOME/.codex/cloud-requirements-cache.json" ]] && cp "$HOME/.codex/cloud-requirements-cache.json" "$AGENT_TMPDIR/.codex/cloud-requirements-cache.json"

if [[ -f "$HOME/.codex/config.toml" ]]; then
  python3 "$SCRIPT_DIR/scripts/sanitize-codex-config.py" "$HOME/.codex/config.toml" "$AGENT_TMPDIR/.codex/config.toml"
  info "Sanitized .codex/config.toml"
fi

# Add trust entries for container repo paths + copy project auth
for repo_spec in "${REPOS[@]}"; do
  repo_path="$(repo_path_from_spec "$repo_spec")"
  repo_name=$(basename "$repo_path")
  printf '\n[projects."/repos/%s"]\ntrust_level = "trusted"\n' "$repo_name" \
    >> "$AGENT_TMPDIR/.codex/config.toml"
  if [[ -f "$repo_path/.codex/auth.json" ]]; then
    mkdir -p "$AGENT_TMPDIR/.codex/projects/$repo_name"
    cp "$repo_path/.codex/auth.json" "$AGENT_TMPDIR/.codex/projects/$repo_name/auth.json"
  fi
done

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

# Agent config mounts (both agents always available)
DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.claude:/home/agent/.claude:rw")
[[ -f "$AGENT_TMPDIR/.claude.json" ]] && DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.claude.json:/home/agent/.claude.json:rw")
DOCKER_ARGS+=("-v" "$AGENT_TMPDIR/.codex:/home/agent/.codex:rw")

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
  repo_path="$(repo_path_from_spec "$repo_spec")"
  repo_mode="$(repo_mode_from_spec "$repo_spec")"

  [[ -d "$repo_path" ]] || die "Repository not found: $repo_path"

  # Override mode based on phase for safety
  case "$PHASE" in
    plan)   repo_mode="ro" ;;   # Plan never writes to repos
    review) repo_mode="ro" ;;   # Review never writes to repos
    dev)    ;;                   # Dev respects the provided mode
  esac

  repo_name=$(basename "$repo_path")
  DOCKER_ARGS+=("-v" "$repo_path:/repos/$repo_name:$repo_mode")

  # Overlay sanitized .codex/config.toml if present (strip host-path [projects.*] sections)
  if [[ -f "$repo_path/.codex/config.toml" ]]; then
    sanitized="$AGENT_TMPDIR/.codex/repo-configs/$repo_name-config.toml"
    mkdir -p "$AGENT_TMPDIR/.codex/repo-configs"
    python3 "$SCRIPT_DIR/scripts/sanitize-codex-config.py" "$repo_path/.codex/config.toml" "$sanitized"
    DOCKER_ARGS+=("-v" "$sanitized:/repos/$repo_name/.codex/config.toml:ro")
    info "Overlaid sanitized .codex/config.toml for $repo_name"
  fi
done

# Phase-specific environment
if [[ "$PHASE" == "dev" && -n "$SPEC" ]]; then
  DOCKER_ARGS+=("-e" "HARNESS_SPEC=$SPEC")
fi

if [[ "$PHASE" == "review" ]]; then
  DOCKER_ARGS+=("-e" "HARNESS_BRANCHES=$BRANCHES")
  DOCKER_ARGS+=("-e" "HARNESS_REVIEW_SPEC=${REVIEW_SPEC:-stage}")
fi

# Image and command — start detached first so we can init firewall as root
DOCKER_ARGS+=("$IMAGE_NAME")

# --- Launch ---
info "Phase:    $PHASE"
info "Project:  $PROJECT"
info "Agent:    ${AGENT:-shell (both agents available)}"
info "Network:  $NETWORK_PROFILE"
info "Repos:    ${REPOS[*]}"
[[ -n "$SPEC" ]] && info "Spec:     $SPEC"
[[ -n "$BRANCHES" ]] && info "Branches: $BRANCHES"
[[ -n "$REVIEW_SPEC" ]] && info "Base:     $REVIEW_SPEC"
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
