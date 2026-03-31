#!/bin/bash
set -euo pipefail

# Agent Harness v0 — Container entrypoint
# Runs as the agent user. No root access.
# Firewall and GitHub auth are initialized by harness.sh before this runs.

# Source PATH setup (fnm/node, uv/python) — needed for codex/claude binaries
# fnm env doesn't work in non-interactive script subshells, so add node bin directly
FNM_NODE_BIN=$(echo "$HOME"/.fnm/node-versions/*/installation/bin | head -1)
export PATH="$FNM_NODE_BIN:$HOME/.fnm:$HOME/.local/bin:$PATH"

# Mark all mounted repos as git safe directories (host-mounted, different UID)
for repo_dir in /repos/*/; do
  git config --global --add safe.directory "${repo_dir%/}" 2>/dev/null || true
done

# Set working directory based on phase
case "${HARNESS_ROLE:-review}" in
  plan)
    cd /cookbooks
    ;;
  dev|review)
    FIRST_REPO=$(ls /repos/ 2>/dev/null | head -1)
    if [[ -n "$FIRST_REPO" ]]; then
      cd "/repos/$FIRST_REPO"
    else
      cd /workspace
    fi
    ;;
  *)
    cd /workspace
    ;;
esac

# --- Build dynamic repo list for prompt templates ---
build_repo_list() {
  local list=""
  for repo_dir in /repos/*/; do
    [[ -d "$repo_dir" ]] || continue
    local name
    name=$(basename "$repo_dir")
    if [ -w "$repo_dir" ]; then
      list="${list}- /repos/${name} (read-write)\n"
    else
      list="${list}- /repos/${name} (read-only)\n"
    fi
  done
  list="${list}- /cookbooks (read-write, context repository)"
  echo -e "$list"
}

# --- Test mode: --print-prompt prints generated prompt without exec'ing ---
PRINT_PROMPT=false
if [[ "${1:-}" == "--print-prompt" ]]; then
  PRINT_PROMPT=true
  shift
fi

# --- Launch agent helper ---
launch_agent() {
  local prompt="$1"
  local cmd=""
  case "${HARNESS_AGENT:-}" in
    codex)
      cmd="codex --dangerously-bypass-approvals-and-sandbox"
      ;;
    claude-code)
      cmd="claude --dangerously-skip-permissions"
      ;;
    *)
      return 1
      ;;
  esac
  if [[ "$PRINT_PROMPT" == "true" ]]; then
    echo "LAUNCH: $cmd"
    echo "$prompt"
    exit 0
  fi
  exec $cmd "$prompt"
}

# --- Auto-launch based on phase ---
case "${HARNESS_ROLE:-}" in
  plan)
    # Plan mode: always launch agent with repo context
    if [[ -n "${HARNESS_AGENT:-}" ]]; then
      REPO_LIST=$(build_repo_list)
      PROMPT="You are in plan mode. Your job is to research, write specs, and create tickets.

Available repositories:
${REPO_LIST}

The context repository at /cookbooks is where specs and notes are written.
Repositories under /repos/ are mounted read-only for reference.

I will give you instructions next."
      launch_agent "$PROMPT"
    fi
    ;;

  dev)
    # Dev mode with spec: launch agent with dev prompt template
    if [[ -n "${HARNESS_SPEC:-}" && -n "${HARNESS_AGENT:-}" ]]; then
      REPO_LIST=$(build_repo_list)
      PROMPT="Read the spec file at ${HARNESS_SPEC} and execute the tasks described in it.

Available repositories:
${REPO_LIST}

IMPORTANT: Before making any code changes, create a new git branch from the current HEAD of the repository you are working in. Do not commit directly to the checked-out branch. Use \`git checkout -b <branch-name>\` or \`git worktree add\` if you need to work across multiple branches simultaneously."
      launch_agent "$PROMPT"
    fi
    ;;

  review)
    # Review mode with branches: launch agent with review coordinator template
    if [[ -n "${HARNESS_BRANCHES:-}" && -n "${HARNESS_AGENT:-}" ]]; then
      REPO_LIST=$(build_repo_list)
      PROJECT="${HARNESS_PROJECT:-}"
      REVIEW_SPEC_NAME="${HARNESS_REVIEW_SPEC:-stage}_adversarial_review_spec.md"
      COORDINATOR="/cookbooks/${PROJECT}/prompts/parallel_adversarial_review_coordinator_prompt.md"
      REVIEW_SPEC_PATH="/cookbooks/${PROJECT}/prompts/${REVIEW_SPEC_NAME}"
      OUTPUT_PATH="/cookbooks/${PROJECT}/adversarial-review/"

      # Validate required files exist before launching agent
      if [[ ! -f "$COORDINATOR" ]]; then
        echo "ERROR: Coordinator prompt not found: $COORDINATOR" >&2
        echo "Create it or check --project path." >&2
        exit 1
      fi
      if [[ ! -f "$REVIEW_SPEC_PATH" ]]; then
        echo "ERROR: Review spec not found: $REVIEW_SPEC_PATH" >&2
        echo "Check --base value (stage or main)." >&2
        exit 1
      fi

      BRANCH_LIST=""
      IFS=',' read -ra BRANCH_ARRAY <<< "${HARNESS_BRANCHES}"
      for branch in "${BRANCH_ARRAY[@]}"; do
        BRANCH_LIST="${BRANCH_LIST}  ${branch}\n"
      done

      PROMPT="Use ${COORDINATOR} as the orchestration instructions.

Set:
- review_spec_path = ${REVIEW_SPEC_PATH}
- output_path = ${OUTPUT_PATH}

Set branch_list to:
$(echo -e "$BRANCH_LIST")

Available repositories:
${REPO_LIST}

Read both files from disk and execute the reviews accordingly.
Launch parallel branch reviews when feasible.
Write one report per branch under output_path.
Return the list of report paths plus a short risk summary per branch.
If a branch cannot be fully verified safely, say so explicitly."
      launch_agent "$PROMPT"
    fi
    ;;
esac

# Fallback: drop into shell (no spec/branches, or agent launch returned 1)
exec "$@"
