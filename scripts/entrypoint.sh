#!/bin/bash
set -euo pipefail

# Agent Harness v0 — Container entrypoint
# Runs as the agent user. No root access.
# Firewall and GitHub auth are initialized by harness.sh before this runs.

# Mark all mounted repos as git safe directories (host-mounted, different UID)
for repo_dir in /repos/*/; do
  git config --global --add safe.directory "${repo_dir%/}" 2>/dev/null || true
done

# Set working directory based on phase
case "${HARNESS_ROLE:-review}" in
  plan)
    # Planning: work in the context repo where specs are written
    cd /cookbooks
    ;;
  dev)
    # Development: work in the first mounted repo
    FIRST_REPO=$(ls /repos/ 2>/dev/null | head -1)
    if [[ -n "$FIRST_REPO" ]]; then
      cd "/repos/$FIRST_REPO"
    else
      cd /workspace
    fi
    ;;
  review)
    # Review: work in the first mounted repo (read-only)
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

# Execute the provided command (default: zsh)
exec "$@"
