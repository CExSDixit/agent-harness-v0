#!/bin/bash
set -euo pipefail

# Agent Harness v0 — Container entrypoint
# Runs as the agent user. No root access.
# Firewall is already initialized by harness.sh before this runs.

# Set up fnm/node in PATH
export PATH="$HOME/.fnm:$HOME/.local/bin:$PATH"
eval "$($HOME/.fnm/fnm env 2>/dev/null)" || true

cd /workspace

# Execute the provided command (default: zsh)
exec "$@"
