#!/bin/bash
# Agent Harness v0 — Regression test suite
#
# Three tiers:
#   1. Arg parsing — calls harness.sh --dry-run, checks resolved values
#   2. Entrypoint prompts — calls entrypoint.sh --print-prompt, checks generated prompts
#   3. Smoke test — real codex exec end-to-end
#
# Usage: ./test-harness.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

PASS=0
FAIL=0
ERRORS=""

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { ((PASS++)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { ((FAIL++)); ERRORS="${ERRORS}\n  - $1"; echo -e "  ${RED}FAIL${NC} $1"; }

# Find test repo
TEST_REPO=""
for c in ~/git/lextegrity/ai-cockpit ~/git/ai-cockpit; do
  [[ -d "${c/#\~/$HOME}" ]] && TEST_REPO="${c/#\~/$HOME}" && break
done
TEST_REPO_NAME=$(basename "${TEST_REPO:-none}")

echo "=== Prerequisites ==="
[[ -z "${COOKBOOKS_PATH:-}" ]] && { echo "COOKBOOKS_PATH not set"; exit 1; }
[[ -z "$TEST_REPO" ]] && { echo "No test repo found"; exit 1; }
echo "Repo: $TEST_REPO_NAME"

# ============================================================
echo ""
echo "=== Tier 1: Arg Parsing (harness.sh --dry-run) ==="
# ============================================================

# Plan mode defaults
OUT=$("$SCRIPT_DIR/harness.sh" plan --project test --repos "$TEST_REPO:ro" --dry-run 2>&1)
[[ "$OUT" == *"AGENT=claude-code"* ]] && pass "plan defaults to claude-code" || fail "plan agent: $OUT"
[[ "$OUT" == *"NETWORK=plan"* ]] && pass "plan defaults to plan network" || fail "plan network: $OUT"

# Plan with codex override
OUT=$("$SCRIPT_DIR/harness.sh" plan --project test --repos "$TEST_REPO:ro" --agent codex --dry-run 2>&1)
[[ "$OUT" == *"AGENT=codex"* ]] && pass "plan --agent codex override" || fail "plan codex: $OUT"

# Dev with spec defaults to claude-code
OUT=$("$SCRIPT_DIR/harness.sh" dev --project test --repos "$TEST_REPO:rw" --spec Q-47-mcp-validation-handoff.md --dry-run 2>&1)
[[ "$OUT" == *"AGENT=claude-code"* ]] && pass "dev+spec defaults to claude-code" || fail "dev+spec agent: $OUT"
[[ "$OUT" == *"NETWORK=python-dev"* ]] && pass "dev defaults to python-dev network" || fail "dev network: $OUT"

# Dev without spec — no agent
OUT=$("$SCRIPT_DIR/harness.sh" dev --project test --repos "$TEST_REPO:rw" --dry-run 2>&1 | grep "^AGENT=")
[[ "$OUT" == "AGENT=" ]] && pass "dev no-spec has no default agent" || fail "dev no-spec: $OUT"

# Agent alias (use a real spec filename)
OUT=$("$SCRIPT_DIR/harness.sh" dev --project test --repos "$TEST_REPO:rw" --agent claude --spec Q-47-mcp-validation-handoff.md --dry-run 2>&1)
[[ "$OUT" == *"AGENT=claude-code"* ]] && pass "--agent claude → claude-code" || fail "alias: $OUT"

# Review defaults
OUT=$("$SCRIPT_DIR/harness.sh" review --project test --repos "$TEST_REPO:ro" --branches feat/test --dry-run 2>&1)
[[ "$OUT" == *"AGENT=codex"* ]] && pass "review defaults to codex" || fail "review agent: $OUT"
[[ "$OUT" == *"REVIEW_SPEC=stage"* ]] && pass "review defaults to stage base" || fail "review base: $OUT"
[[ "$OUT" == *"NETWORK=review-only"* ]] && pass "review defaults to review-only" || fail "review network: $OUT"

# Review with --base main
OUT=$("$SCRIPT_DIR/harness.sh" review --project test --repos "$TEST_REPO:ro" --branches feat/test --base main --dry-run 2>&1)
[[ "$OUT" == *"REVIEW_SPEC=main"* ]] && pass "review --base main" || fail "review main: $OUT"

# Spec resolution — relative path
OUT=$("$SCRIPT_DIR/harness.sh" dev --project caseiq/projects/ai-cockpit --repos "$TEST_REPO:rw" --spec mcp-search-fetch/Q-46-changelog.md --dry-run 2>&1)
[[ "$OUT" == *"/cookbooks/caseiq/projects/ai-cockpit/mcp-search-fetch/Q-46-changelog.md"* ]] \
  && pass "relative spec path resolves" || fail "spec relative: $OUT"

# Spec resolution — filename only
OUT=$("$SCRIPT_DIR/harness.sh" dev --project test --repos "$TEST_REPO:rw" --spec Q-47-mcp-validation-handoff.md --dry-run 2>&1)
[[ "$OUT" == *"/cookbooks/"*"Q-47-mcp-validation-handoff.md"* ]] \
  && pass "filename-only spec resolves" || fail "spec filename: $OUT"

# Invalid agent
OUT=$("$SCRIPT_DIR/harness.sh" dev --project test --repos "$TEST_REPO:rw" --agent bogus --dry-run 2>&1)
[[ "$OUT" == *"Unknown agent"* ]] && pass "invalid agent rejected" || fail "invalid agent: $OUT"

# ============================================================
echo ""
echo "=== Tier 2: Entrypoint Prompts (--print-prompt) ==="
# ============================================================

if docker image inspect agent-harness:latest &>/dev/null; then
  docker run --rm -d --name htest-prompts \
    -v "$COOKBOOKS_PATH:/cookbooks:rw" \
    -v "$TEST_REPO:/repos/$TEST_REPO_NAME:ro" \
    agent-harness:latest sleep infinity >/dev/null 2>&1

  # Plan — launches claude with repo context
  OUT=$(docker exec -u agent \
    -e HARNESS_ROLE=plan -e HARNESS_AGENT=claude-code -e HARNESS_PROJECT=test \
    htest-prompts /usr/local/bin/entrypoint.sh --print-prompt 2>&1)
  [[ "$OUT" == *"LAUNCH: claude"* ]] && pass "plan launches claude" || fail "plan launch: $OUT"
  [[ "$OUT" == *"/repos/$TEST_REPO_NAME"* ]] && pass "plan prompt has repo list" || fail "plan repos: $OUT"
  [[ "$OUT" == *"/cookbooks"* ]] && pass "plan prompt has cookbooks" || fail "plan cookbooks: $OUT"

  # Dev+spec+codex
  OUT=$(docker exec -u agent \
    -e HARNESS_ROLE=dev -e HARNESS_AGENT=codex -e HARNESS_SPEC=/cookbooks/test.md -e HARNESS_PROJECT=test \
    htest-prompts /usr/local/bin/entrypoint.sh --print-prompt 2>&1)
  [[ "$OUT" == *"LAUNCH: codex"* ]] && pass "dev+spec launches codex" || fail "dev codex: $OUT"
  [[ "$OUT" == *"test.md"* ]] && pass "dev prompt has spec path" || fail "dev spec: $OUT"
  [[ "$OUT" == *"worktree"* || "$OUT" == *"branch"* ]] && pass "dev prompt has worktree instruction" || fail "dev worktree: $OUT"

  # Dev+spec+claude
  OUT=$(docker exec -u agent \
    -e HARNESS_ROLE=dev -e HARNESS_AGENT=claude-code -e HARNESS_SPEC=/cookbooks/test.md -e HARNESS_PROJECT=test \
    htest-prompts /usr/local/bin/entrypoint.sh --print-prompt 2>&1)
  [[ "$OUT" == *"LAUNCH: claude"* ]] && pass "dev+claude launches claude" || fail "dev claude: $OUT"

  # Dev no spec — shell fallback
  OUT=$(docker exec -u agent \
    -e HARNESS_ROLE=dev -e HARNESS_PROJECT=test \
    htest-prompts /usr/local/bin/entrypoint.sh echo "SHELL_OK" 2>&1)
  [[ "$OUT" == *"SHELL_OK"* ]] && pass "dev no-spec → shell fallback" || fail "dev fallback: $OUT"

  # Review — launches codex with branch and coordinator
  OUT=$(docker exec -u agent \
    -e HARNESS_ROLE=review -e HARNESS_AGENT=codex \
    -e HARNESS_BRANCHES=feat/Q-28-oauth -e HARNESS_PROJECT=caseiq/projects/ai-cockpit \
    -e HARNESS_REVIEW_SPEC=stage \
    htest-prompts /usr/local/bin/entrypoint.sh --print-prompt 2>&1)
  [[ "$OUT" == *"LAUNCH: codex"* ]] && pass "review launches codex" || fail "review launch: $OUT"
  [[ "$OUT" == *"feat/Q-28-oauth"* ]] && pass "review prompt has branch" || fail "review branch: $OUT"
  [[ "$OUT" == *"stage_adversarial_review_spec"* ]] && pass "review prompt has review spec" || fail "review spec: $OUT"
  [[ "$OUT" == *"coordinator"* ]] && pass "review prompt references coordinator" || fail "review coord: $OUT"

  docker stop htest-prompts >/dev/null 2>&1
else
  fail "image not built — skipping Tier 2"
fi

# ============================================================
echo ""
echo "=== Tier 3: Smoke Test ==="
# ============================================================

if docker image inspect agent-harness:latest &>/dev/null; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"; docker stop htest-smoke >/dev/null 2>&1' EXIT

  # Claude credentials
  mkdir -p "$TMP/.claude"
  [[ -f "$HOME/.claude/credentials.json" ]] && cp "$HOME/.claude/credentials.json" "$TMP/.claude/"
  [[ -f "$HOME/.claude/settings.json" ]] && cp "$HOME/.claude/settings.json" "$TMP/.claude/"
  [[ -f "$HOME/.claude.json" ]] && cp "$HOME/.claude.json" "$TMP/.claude.json"

  # Codex credentials
  mkdir -p "$TMP/.codex"
  [[ -f "$HOME/.codex/auth.json" ]] && cp "$HOME/.codex/auth.json" "$TMP/.codex/"
  [[ -f "$HOME/.codex/cloud-requirements-cache.json" ]] && cp "$HOME/.codex/cloud-requirements-cache.json" "$TMP/.codex/"
  if [[ -f "$HOME/.codex/config.toml" ]]; then
    python3 "$SCRIPT_DIR/scripts/sanitize-codex-config.py" "$HOME/.codex/config.toml" "$TMP/.codex/config.toml"
    printf '\n[projects."/repos/%s"]\ntrust_level = "trusted"\n' "$TEST_REPO_NAME" >> "$TMP/.codex/config.toml"
  fi

  SMOKE_VOLS=(
    -v "$TMP/.claude:/home/agent/.claude:rw"
    -v "$TMP/.codex:/home/agent/.codex:rw"
    -v "$COOKBOOKS_PATH:/cookbooks:rw"
    -v "$TEST_REPO:/repos/$TEST_REPO_NAME:ro"
  )
  [[ -f "$TMP/.claude.json" ]] && SMOKE_VOLS+=(-v "$TMP/.claude.json:/home/agent/.claude.json:rw")

  docker run --rm -d --name htest-smoke \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    ${CLAUDE_CODE_OAUTH_TOKEN:+-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN"} \
    ${OPENAI_API_KEY:+-e "OPENAI_API_KEY=$OPENAI_API_KEY"} \
    "${SMOKE_VOLS[@]}" \
    agent-harness:latest sleep infinity >/dev/null 2>&1

  docker exec -u root htest-smoke /usr/local/bin/init-firewall.sh default >/dev/null 2>&1

  # Bubblewrap
  docker run --rm agent-harness:latest which bwrap >/dev/null 2>&1 \
    && pass "bubblewrap installed" || fail "bubblewrap missing"

  # Both agents on PATH
  docker exec -u agent htest-smoke /usr/local/bin/entrypoint.sh bash -c 'which codex && which claude' >/dev/null 2>&1 \
    && pass "both agents on PATH" || fail "agents not on PATH"

  # Codex exec hello world
  OUT=$(docker exec -u agent -w "/repos/$TEST_REPO_NAME" htest-smoke \
    /usr/local/bin/entrypoint.sh codex exec --dangerously-bypass-approvals-and-sandbox "echo harness-smoke-ok" 2>&1)
  [[ "$OUT" == *"harness-smoke-ok"* ]] && pass "codex exec end-to-end" || fail "codex exec: ${OUT:0:200}"

  # Network profiles
  ALL_OK=true
  for profile in "$SCRIPT_DIR"/profiles/*.conf; do
    name=$(basename "$profile" .conf)
    [[ "$name" == "permissive" ]] && continue
    grep -q "chatgpt.com" "$profile" || { fail "chatgpt.com missing from $name"; ALL_OK=false; }
  done
  $ALL_OK && pass "chatgpt.com in all profiles"

  docker stop htest-smoke >/dev/null 2>&1
else
  fail "image not built — skipping Tier 3"
fi

# ============================================================
echo ""
echo "=============================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
if [[ $FAIL -gt 0 ]]; then
  echo -e "Failures:${ERRORS}"
  exit 1
fi
echo "=============================="
