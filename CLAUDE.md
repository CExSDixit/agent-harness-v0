# CLAUDE.md — Agent Harness v0

## What this is

A sandboxed execution environment for AI coding agents (Claude Code, Codex). One Docker image, parameterized at runtime by phase (plan/dev/review), agent type, and network profile.

## Repository structure

```
agent-harness-v0/
├── Dockerfile              # Single image for all phases and agents
├── harness.sh              # Parameterized launch script
├── scripts/
│   ├── entrypoint.sh       # Container entrypoint (user-level shell setup, no root)
│   ├── init-firewall.sh    # iptables/ipset setup from network profile (root only)
│   ├── github-auth.sh      # GitHub App PEM → installation token exchange (root only)
│   ├── allow-domain        # Hot-add domain to allowlist (root only, no restart)
│   ├── deny-domain         # Hot-remove domain from allowlist (root only)
│   └── list-allowed        # Show current allowlist (root only)
├── profiles/               # Network allowlist profiles (.conf files)
│   ├── default.conf        # Minimum: agent APIs + GitHub + package registries
│   ├── plan.conf           # Default + documentation sites
│   ├── python-dev.conf     # Default + Python ecosystem
│   ├── node-dev.conf       # Default + Node ecosystem
│   └── review-only.conf    # Agent APIs + GitHub fetch only
├── CLAUDE.md               # This file
└── .gitignore
```

## Key commands

```bash
# Build the image
docker build -t agent-harness:latest .

# Run regression tests (ALWAYS run after changes to harness.sh, entrypoint.sh, or Dockerfile)
./test-harness.sh

# Launch phases via harness.sh
./harness.sh plan --project <project-path> --repos <repo:mode>
./harness.sh dev --project <project-path> --repos <repo:rw> --spec <filename-or-path>
./harness.sh dev --project <project-path> --repos <repo:rw>              # shell mode
./harness.sh review --project <project-path> --repos <repo:ro> --branches <b1,b2>

# Agent defaults: plan→claude, dev+spec→claude, review→codex
# Override with --agent codex or --agent claude
# Both agents are always authenticated in every container

# Dry-run (print resolved config, no Docker)
./harness.sh dev --project <path> --repos <repo:rw> --spec myspec.md --dry-run

# Inside the container — godmode aliases (bypass all permission prompts)
claude-yolo                # claude --dangerously-skip-permissions
codex-yolo                 # codex --dangerously-bypass-approvals-and-sandbox

# Hot-reload network policies (operator only, from host terminal)
docker exec -u root <container> allow-domain docs.python.org
docker exec -u root <container> deny-domain docs.python.org
docker exec -u root <container> list-allowed
```

## Testing

Run `./test-harness.sh` after any changes. The test suite has three tiers:

1. **Arg parsing** — calls `harness.sh --dry-run`, validates resolved config (no Docker)
2. **Entrypoint prompts** — calls `entrypoint.sh --print-prompt`, validates generated prompts (one container)
3. **Smoke test** — real `codex exec` end-to-end (one container with firewall)

Tests call real script functions via `--dry-run` and `--print-prompt` hooks. No logic is duplicated between tests and scripts (except credential file copies which are simple `cp` commands).

## Security model

The agent process runs as the unprivileged `agent` user inside the container:
- **No sudo access** — the agent user has no entries in sudoers
- **No root escalation** — firewall scripts, ipset, iptables are only accessible to root
- **Network policies are operator-only** — only the operator can modify the allowlist via `docker exec -u root` from the host
- **Firewall init happens before the agent session** — `harness.sh` starts the container detached, inits firewall as root, then attaches the agent session. The agent process never runs as root.
- **Fail-closed** — if firewall initialization fails, the container is stopped. It never runs without network isolation.
- **Credentials are mounted, not baked** — GitHub App PEM root-only, per-agent config dirs isolated from host and from each other
- **Phase-enforced mount modes** — plan and review force read-only on repos regardless of what the operator passes

## Launch sequence (what harness.sh does)

1. Creates per-agent temp config dir (seeded from host credentials, read-only copy)
2. Starts container detached (`sleep infinity`)
3. Runs `docker exec -u root` to init firewall with selected network profile
4. If firewall fails → stops container, exits with error (fail-closed)
5. Attaches interactive session as `agent` user via `docker exec -it -u agent`
6. On exit: stops container, cleans up temp config dir

## Important

- Never push without explicit user authorization
- The harness enforces repo mount modes: plan and review force read-only on repos regardless of what the user passes
- Git auth uses GitHub App installation tokens (HTTPS), not SSH keys
- The GitHub App PEM is mounted root-only; the agent user cannot read it directly
- Network profiles are loaded at container start via init-firewall.sh
- Domains can be added/removed at runtime by the operator without container restart

## Design context

Project code: `ah0`
Security model: `security-model.md`
