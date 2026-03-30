# CLAUDE.md — Agent Harness v0

## What this is

A sandboxed execution environment for AI coding agents (Claude Code, Codex). One Docker image, parameterized at runtime by phase (plan/dev/review), agent type, and network profile.

## Repository structure

```
agent-harness-v0/
├── Dockerfile              # Single image for all phases and agents
├── harness.sh              # Parameterized launch script
├── scripts/
│   ├── entrypoint.sh       # Container entrypoint (inits firewall, then shell)
│   ├── init-firewall.sh    # iptables/ipset setup from network profile
│   ├── allow-domain        # Hot-add domain to allowlist (no restart)
│   ├── deny-domain         # Hot-remove domain from allowlist
│   └── list-allowed        # Show current allowlist
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

# Hot-reload network policies (from host, while container is running)
docker exec <container> allow-domain docs.python.org
docker exec <container> deny-domain docs.python.org
docker exec <container> list-allowed
```

## Design context

Full design spec: `~/git/cookbooks/projects/agent-harness-v0/design.md`
Project code: `ah0`
Daily notes tag: `[ah0]`

## Important

- Never push without explicit user authorization
- The harness enforces repo mount modes: plan and review force read-only on repos regardless of what the user passes
- API keys are passed via environment variables, never baked into the image
- SSH keys are mounted read-only, scoped to a deploy key (not personal keyring)
- Network profiles are loaded at container start via init-firewall.sh
- Domains can be added/removed at runtime without container restart
