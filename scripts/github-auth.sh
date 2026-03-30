#!/bin/bash
set -euo pipefail

# Agent Harness v0 — GitHub App token exchange
# Generates a short-lived installation token from a GitHub App PEM file.
# Configures git (HTTPS) and gh CLI to use the token.
#
# Required env vars:
#   GITHUB_APP_ID              - GitHub App ID (numeric)
#   GITHUB_APP_INSTALLATION_ID - Installation ID (numeric)
#   GITHUB_APP_PEM_PATH        - Path to the PEM private key file inside the container
#
# The installation token expires after 1 hour. For sessions longer than that,
# re-run this script from the host: docker exec -u root <container> /usr/local/bin/github-auth.sh

if [[ -z "${GITHUB_APP_ID:-}" || -z "${GITHUB_APP_INSTALLATION_ID:-}" || -z "${GITHUB_APP_PEM_PATH:-}" ]]; then
  echo "[github-auth] Skipping — GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, or GITHUB_APP_PEM_PATH not set"
  exit 0
fi

if [[ ! -f "$GITHUB_APP_PEM_PATH" ]]; then
  echo "[github-auth] ERROR: PEM file not found: $GITHUB_APP_PEM_PATH"
  exit 1
fi

# 1. Create JWT signed with the PEM (valid 10 minutes)
NOW=$(date +%s)
IAT=$((NOW - 60))
EXP=$((NOW + 600))

HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${GITHUB_APP_ID}\"}" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$GITHUB_APP_PEM_PATH" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

# 2. Exchange JWT for installation token (valid ~1 hour)
RESPONSE=$(curl -sf -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")

TOKEN=$(echo "$RESPONSE" | jq -r .token)
EXPIRES=$(echo "$RESPONSE" | jq -r .expires_at)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "[github-auth] ERROR: Failed to get installation token"
  echo "[github-auth] Response: $RESPONSE"
  exit 1
fi

# 3. Configure git to use HTTPS with the token (replaces SSH)
AGENT_HOME="${AGENT_HOME:-/home/agent}"
git config --global --replace-all url."https://x-access-token:${TOKEN}@github.com/".insteadOf "git@github.com:"
git config --global --add url."https://x-access-token:${TOKEN}@github.com/".insteadOf "https://github.com/"

# 4. Configure gh CLI
export PATH="$AGENT_HOME/.fnm:$AGENT_HOME/.local/bin:$PATH"
eval "$($AGENT_HOME/.fnm/fnm env 2>/dev/null)" || true
echo "$TOKEN" | gh auth login --with-token 2>/dev/null || echo "[github-auth] Warning: gh auth login failed (gh may not be installed)"

echo "[github-auth] GitHub App token configured (expires: $EXPIRES)"
