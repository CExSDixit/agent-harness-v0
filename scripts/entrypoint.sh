#!/bin/bash
set -euo pipefail

# Agent Harness v0 — Container entrypoint
# Initializes firewall with the selected network profile, then runs the command.

# Set up fnm/node in PATH
export PATH="$HOME/.fnm:$HOME/.local/bin:$PATH"
eval "$($HOME/.fnm/fnm env 2>/dev/null)" || true

# Initialize firewall if we have NET_ADMIN capability
if sudo /usr/local/bin/init-firewall.sh "$HARNESS_NETWORK_PROFILE" 2>/dev/null; then
  echo "[harness] Firewall initialized with profile: $HARNESS_NETWORK_PROFILE"
else
  echo "[harness] Warning: firewall initialization failed (missing NET_ADMIN cap?)"
  echo "[harness] Running without network restrictions"
fi

# Execute the provided command (default: zsh)
exec "$@"
