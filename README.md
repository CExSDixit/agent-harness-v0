# Agent Harness v0

Sandboxed Docker execution environment for AI coding agents (Claude Code, Codex) with network isolation, filesystem scoping, and parallel worktree support.

## Design Overview

The harness runs AI coding agents inside Docker containers instead of on your host machine. The agent process is sandboxed: it can only access files you explicitly mount and network destinations you explicitly allow.

### The Three-Layer Model

```
┌─────────────────────────────────────────────────────────────────┐
│  HOST (your machine)                                             │
│                                                                  │
│  ┌─ Context Repo ──────────────────────────────────────────────┐ │
│  │  Your cross-project knowledge base. Contains:                │ │
│  │  - Specs (implementation plans for each task)                │ │
│  │  - Adversarial review reports (verification of agent work)   │ │
│  │  - Prompt templates (review standards, coordinator prompts)  │ │
│  │  - Project notes, daily capture, workstream tracking         │ │
│  │                                                              │ │
│  │  This is the shared layer that ties everything together.     │ │
│  │  Mounted at /cookbooks in every container.                   │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌─ Code Repos ────────────────────────────────────────────────┐ │
│  │  The actual codebases agents work on. Each repo is mounted   │ │
│  │  separately with explicit access mode (read-write or         │ │
│  │  read-only depending on the phase).                          │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌─ Agent Container ───────────────────────────────────────────┐ │
│  │  Docker container with:                                      │ │
│  │  - Claude Code or Codex (the AI agent)                       │ │
│  │  - Network restricted to allowlisted domains                 │ │
│  │  - No root access, no sudo                                   │ │
│  │  - Only sees mounted paths, nothing else from the host       │ │
│  └──────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### The Three Phases

The harness supports a plan → dev → review workflow. Each phase has different access permissions and a different purpose:

```
  Plan                         Dev                          Review
  ┌──────────────┐            ┌──────────────┐            ┌──────────────┐
  │ Write specs  │   spec     │ Implement    │  branches  │ Verify work  │
  │ Research     │ ────────>  │ Code changes │ ────────>  │ Write report │
  │ Create tasks │            │ Push branches│            │ Find bugs    │
  └──────────────┘            └──────────────┘            └──────────────┘
  Repos: read-only            Repos: read-write           Repos: read-only
  Context: read-write         Context: read-write         Context: read-write
  Network: plan profile       Network: dev profile        Network: review profile
```

Output from one phase becomes input to the next:
- **Plan** produces spec files → passed as `--spec` to **Dev**
- **Dev** produces feature branches → passed as `--branches` to **Review**
- **Review** produces reports written to the context repo

### What Is the Context Repo?

The context repo (`COOKBOOKS_PATH`) is a git repository where you keep project-level knowledge that spans multiple code repos. It serves as the shared layer between you and your agents.

A typical context repo structure:

```
my-context-repo/
├── my-org/
│   └── my-project/
│       ├── PROJ-1-feature.md              # Spec for a task
│       ├── PROJ-2-bugfix.md               # Spec for another task
│       ├── adversarial-review/            # Review reports land here
│       │   ├── feat__proj-1-feature.md
│       │   └── feat__proj-2-bugfix.md
│       └── prompts/                       # Review templates
│           ├── review-spec.md
│           └── coordinator-prompt.md
├── another-org/
│   └── another-project/
│       └── ...
└── daily/
    └── notes.md                           # Optional: daily capture log
```

**You don't need to use this exact structure.** The `--project` flag tells the harness which subdirectory to treat as the current project. You organize the context repo however makes sense for your workflow.

**Why a separate repo?** Because specs, review reports, and notes span multiple code repos. If you're working on a system with a backend repo and an Airflow repo, the spec that describes work across both lives in the context repo, not in either code repo. It's also where adversarial review reports are written — the review agent has read-only access to code repos but read-write access to the context repo.

## Prerequisites

- Docker Desktop, OrbStack, or Colima (any Docker runtime)
- Claude Code CLI and/or Codex CLI installed on the host (for pre-caching credentials)

## Quick Start

```bash
# 1. Build the image
docker build -t agent-harness:latest .

# 2. Configure your context repo path
export COOKBOOKS_PATH=~/git/my-context-repo

# 3. Launch a dev agent
./harness.sh dev \
  --project my-org/my-project \
  --repos ~/git/my-app:rw \
  --agent claude-code \
  --ssh-key ~/.ssh/id_ed25519_deploy \
  --spec /cookbooks/my-org/my-project/PROJ-1-feature.md
```

## Configuration

The harness requires one environment variable:

| Variable | Required | Description |
|---|---|---|
| `COOKBOOKS_PATH` | Yes | Path to your context/notes repo. Mounted at `/cookbooks` in the container. This is where specs, review reports, and prompts live. |
| `HARNESS_SSH_KEY` | No | Default SSH deploy key path. Used if `--ssh-key` is not provided. |

Copy `.env.example` and configure:

```bash
cp .env.example .env
# Edit .env with your paths, then:
source .env
```

## Phases

The harness supports three execution phases. Each phase has a default network profile and enforced mount modes.

### Plan

Write specs, research, create tickets. Repos are mounted **read-only** regardless of what you pass.

```bash
./harness.sh plan \
  --project my-org/my-project \
  --repos ~/git/my-app:ro \
  --agent claude-code
```

Default network profile: `plan` (agent APIs + GitHub + package registries + documentation sites)

### Dev

Implement from a spec. Repos are mounted with the mode you specify.

```bash
./harness.sh dev \
  --project my-org/my-project \
  --repos ~/git/my-app:rw \
  --agent claude-code \
  --ssh-key ~/.ssh/id_ed25519_deploy \
  --spec /cookbooks/my-org/my-project/PROJ-1-feature.md
```

Default network profile: `python-dev`

For parallel execution across multiple specs/branches:

```bash
./harness.sh dev \
  --project my-org/my-project \
  --repos ~/git/my-app:rw ~/git/my-other-repo:rw \
  --agent codex \
  --ssh-key ~/.ssh/id_ed25519_deploy \
  --spec /cookbooks/my-org/my-project/PROJ-1-feature.md,/cookbooks/my-org/my-project/PROJ-2-bugfix.md \
  --parallel
```

### Review

Adversarial review of branches. Repos are mounted **read-only** regardless of what you pass.

```bash
./harness.sh review \
  --project my-org/my-project \
  --repos ~/git/my-app:ro \
  --agent claude-code \
  --branches feat/proj-1-feature,feat/proj-2-bugfix
```

Default network profile: `review-only` (agent APIs + GitHub fetch only, no package registries)

## All Options

```
./harness.sh <phase> [options]

PHASES:
  plan      Write specs and create tickets
  dev       Implement from a spec
  review    Adversarial review of branches

OPTIONS:
  --project <path>         Context repo project path (e.g., my-org/my-project)
  --repos <path:mode>      Repository to mount. Mode is rw or ro. Repeatable.
  --agent <name>           Agent: claude-code (default) or codex
  --network-profile <name> Network profile (see below). Overrides phase default.
  --ssh-key <path>         SSH deploy key to mount (read-only)
  --spec <path>            Spec file path (dev phase, required)
  --branches <b1,b2,...>   Branches to review (review phase, required)
  --parallel               Enable parallel worktree execution (dev phase)
  --name <name>            Container name (default: harness-<phase>-<timestamp>)

ENVIRONMENT VARIABLES:
  COOKBOOKS_PATH           Path to your context/notes repo (required, mounted at /cookbooks)
  HARNESS_SSH_KEY          Default SSH key path (used if --ssh-key not provided)
```

## Network Profiles

Profiles are `.conf` files in `profiles/` — one domain per line, comments start with `#`.

| Profile | What's allowed | Use when |
|---|---|---|
| `default` | Agent APIs, GitHub, pypi, npm | General purpose |
| `plan` | Default + documentation sites | Writing specs, research |
| `python-dev` | Default + Python docs | Python implementation |
| `node-dev` | Default + Node docs | Node.js implementation |
| `review-only` | Agent APIs + GitHub fetch only | Adversarial review |
| `permissive` | All outbound internet | Broad research, unfamiliar deps |

Override the default for any phase:

```bash
./harness.sh dev --network-profile permissive --project ... --repos ... --spec ...
```

### Managing Network Access at Runtime

All network policy changes are **operator-only** — the agent inside the container cannot modify the allowlist. Run these from your host terminal.

**Add a domain (immediate, no restart):**

```bash
docker exec -u root <container-name> allow-domain docs.python.org
```

**Add multiple domains at once:**

```bash
docker exec -u root <container-name> allow-domain docs.python.org stackoverflow.com readthedocs.io
```

**Remove a domain:**

```bash
docker exec -u root <container-name> deny-domain docs.python.org
```

**List currently allowed IPs:**

```bash
docker exec -u root <container-name> list-allowed
```

**Switch to a different profile entirely (flushes and rebuilds all rules):**

```bash
# Open up to permissive mid-session
docker exec -u root <container-name> /usr/local/bin/init-firewall.sh permissive

# Lock back down to a scoped profile
docker exec -u root <container-name> /usr/local/bin/init-firewall.sh python-dev
```

This flushes the existing iptables rules and ipset, then rebuilds from the specified profile. The agent session continues uninterrupted — no restart, no state loss.

**Find your container name:**

The container name is printed when `harness.sh` launches. Or:

```bash
docker ps --filter "name=harness-" --format "{{.Names}}"
```

## Credential Setup (One-Time)

### SSH deploy key

Create a key scoped to the repos you want the agent to access:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_deploy -C "agent-harness-deploy"
```

Add it as a deploy key on each GitHub repo (Settings > Deploy keys). Grant write access for repos the dev agent needs to push to.

### Claude Code / Codex auth

Authenticate on the host first — the harness mounts cached tokens into the container:

```bash
# Claude Code: run once, complete login
claude

# Codex: run once, complete login
codex
```

For OAuth-protected MCP servers, connect to them on the host first so the token is cached. The container uses the cached token; no browser flow runs inside the container.

## How It Works

`harness.sh` does the following:

1. Creates a per-agent temp config directory, seeded from host credentials (read-only copy)
2. Starts the container **detached** (`sleep infinity`)
3. Initializes the firewall **as root** via `docker exec -u root` with the selected network profile
4. If firewall init fails, stops the container and exits (**fail-closed** — never runs without network isolation)
5. Attaches an interactive session **as the `agent` user** via `docker exec -it -u agent`
6. On exit: stops the container, cleans up the temp config directory

The agent process never runs as root. The agent user has no sudo access. Only the operator can modify network policies.

## Operating Containers

### Exec into a running container

Open a second shell into a running agent container (e.g., to inspect files, check git status):

```bash
# As the agent user (same as the agent sees)
docker exec -it <container-name> /bin/zsh

# As root (for network policy changes, debugging)
docker exec -it -u root <container-name> /bin/bash
```

### Copy files in/out

```bash
# Copy a file from host into the container
docker cp ~/path/to/file.md <container-name>:/workspace/file.md

# Copy a report out of the container
docker cp <container-name>:/cookbooks/path/to/report.md ~/Desktop/report.md
```

Note: if your context repo is bind-mounted (which it is by default), files written to `/cookbooks/` inside the container are immediately visible on the host — no copy needed.

### View agent output / logs

```bash
# Follow container logs (entrypoint output, firewall init messages)
docker logs -f <container-name>

# Check what the agent is doing from another terminal
docker exec <container-name> ps aux
```

### List running harness containers

```bash
docker ps --filter "name=harness-"
```

### Stop a container

```bash
# Graceful stop (harness.sh does this on exit)
docker stop <container-name>

# If something is stuck
docker kill <container-name>
```

### Inspect mounts and environment

```bash
# See what's mounted and how
docker inspect <container-name> --format '{{json .Mounts}}' | jq .

# See environment variables
docker exec <container-name> env | grep HARNESS
```

### Recover work from a crashed container

If a container crashes mid-session, work on bind-mounted paths (repos, context repo) is safe — it's on the host filesystem. For worktrees created inside the container on a shared mount:

```bash
# List worktrees that may have been left behind
ls ~/git/my-app/.claude/worktrees/

# Create a branch from a worktree's state
cd <worktree-path>
git checkout -b recovery/salvaged-work
git add -A && git commit -m "Salvaged from crashed container"
```

## Rebuilding the Image

After modifying the Dockerfile, profiles, or scripts:

```bash
docker build -t agent-harness:latest .
```

With Docker layer caching, incremental rebuilds (e.g., adding a profile) take seconds. A full no-cache rebuild takes 2-5 minutes.

### When to rebuild

| Change | Rebuild needed? |
|---|---|
| Edit a network profile `.conf` | Yes (profiles are baked into the image) |
| Add a new profile | Yes |
| Modify Dockerfile (new packages, tools) | Yes |
| Modify `init-firewall.sh` or helper scripts | Yes |
| Change `harness.sh` | No (runs on host) |
| Add domains at runtime via `allow-domain` | No |

## Security

See [security-model.md](security-model.md) for the full security model, threat analysis, host network access considerations, and residual risks.
