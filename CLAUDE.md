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

# Launch phases via harness.sh
./harness.sh plan --project <cookbooks-path> --repos <repo:mode> --agent claude-code
./harness.sh dev --project <cookbooks-path> --repos <repo:rw> --agent claude-code --spec <path>
./harness.sh review --project <cookbooks-path> --repos <repo:ro> --agent claude-code --branches <b1,b2>

# Hot-reload network policies (operator only, from host terminal)
docker exec -u root <container> allow-domain docs.python.org
docker exec -u root <container> deny-domain docs.python.org
docker exec -u root <container> list-allowed
```

## Security model

The agent process runs as the unprivileged `agent` user inside the container:
- **No sudo access** — the agent user has no entries in sudoers
- **No root escalation** — firewall scripts, ipset, iptables are only accessible to root
- **Network policies are operator-only** — only the operator can modify the allowlist via `docker exec -u root` from the host
- **Firewall init happens before the agent session** — `harness.sh` starts the container detached, inits firewall as root, then attaches the agent session. The agent process never runs as root.
- **Fail-closed** — if firewall initialization fails, the container is stopped. It never runs without network isolation.
- **Credentials are mounted, not baked** — SSH keys read-only, per-agent config dirs isolated from host and from each other
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
- SSH keys are mounted read-only, scoped to a deploy key (not personal keyring)
- Network profiles are loaded at container start via init-firewall.sh
- Domains can be added/removed at runtime by the operator without container restart

## Design context

Project code: `ah0`
Security model: `security-model.md`
