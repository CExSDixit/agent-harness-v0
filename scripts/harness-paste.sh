#!/bin/bash
# Agent Harness v0 — Clipboard image paste for containerized agents
#
# Saves the clipboard image to the shared cookbooks mount point and copies
# the container-relative path to the clipboard. The user can then Cmd+V
# the path in the container terminal after typing @.
#
# Flow:
#   1. User screenshots (Cmd+Shift+4)
#   2. User presses keyboard shortcut (triggers this script)
#   3. Image saved to $COOKBOOKS_PATH/.harness-images/
#   4. Container path copied to clipboard: /cookbooks/.harness-images/<filename>
#   5. macOS notification confirms the save
#   6. User types @ then Cmd+V in container terminal
#
# Setup: assign this script to a keyboard shortcut via Automator Quick Action
# Requires: pngpaste (brew install pngpaste)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source .env for COOKBOOKS_PATH
[[ -f "$SCRIPT_DIR/../.env" ]] && set -a && source "$SCRIPT_DIR/../.env" && set +a

COOKBOOKS="${COOKBOOKS_PATH:-$HOME/git/cookbooks}"
COOKBOOKS="${COOKBOOKS/#\~/$HOME}"
IMG_DIR="$COOKBOOKS/.harness-images"
mkdir -p "$IMG_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILENAME="paste-${TIMESTAMP}.png"
FILEPATH="$IMG_DIR/$FILENAME"
CONTAINER_PATH="/cookbooks/.harness-images/$FILENAME"

if pngpaste "$FILEPATH" 2>/dev/null; then
  # Copy the container-relative path to clipboard (user can Cmd+V in terminal)
  echo -n "$CONTAINER_PATH" | pbcopy
  osascript -e "display notification \"$CONTAINER_PATH\" with title \"Harness Paste\" subtitle \"Path copied to clipboard\""
else
  osascript -e "display notification \"No image in clipboard\" with title \"Harness Paste\" subtitle \"Take a screenshot first\""
  exit 1
fi
