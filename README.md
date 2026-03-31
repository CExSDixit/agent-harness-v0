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

**The context repo is yours to manage.** The harness doesn't impose a structure — it only controls read/write permissions (always read-write for the context repo across all phases). How you organize specs, prompts, review templates, notes, and project folders is entirely your choice. The `--project` flag is just a hint for MCP config resolution, not a required directory layout.

## Prerequisites

### Host dependencies

`harness.sh` runs on your host machine and requires:

| Dependency | Why | Install |
|---|---|---|
| **Docker** | Container runtime | [Docker Desktop](https://docker.com/products/docker-desktop), [OrbStack](https://orbstack.dev), or [Colima](https://github.com/abiosoft/colima) |
| **Python 3** | Config sanitization (JSON/TOML rewriting) | Pre-installed on macOS. `brew install python3` or `apt install python3` |
| **jq** | GitHub meta API parsing in firewall init | `brew install jq` or `apt install jq` |
| **Bash 3.2+** | harness.sh shell | Pre-installed on macOS and Linux |
| **pngpaste** | Clipboard image paste workflow (macOS only, optional) | `brew install pngpaste` |

Standard utilities also used: `curl`, `sed`, `cp`, `mkdir`, `mktemp`, `basename`, `dirname` (all pre-installed on macOS and Linux).

### Agent setup on host

The harness mounts credentials from your host machine into containers. You must have the agents installed and authenticated on the host **before** using the harness.

**Claude Code:**
```bash
# Install
curl -fsSL https://claude.ai/install.sh | bash

# Authenticate (opens browser)
claude

# Generate container token (required — Claude Code stores auth in macOS Keychain, not files)
claude setup-token
# Copy the token into your .env as CLAUDE_CODE_OAUTH_TOKEN
```

**Codex:**
```bash
# Install
npm install -g @openai/codex

# Authenticate (opens browser)
codex

# For OAuth MCP servers, authenticate each one:
codex mcp login <server-name>
```

### How harness.sh picks up agent configs

When you launch a container, `harness.sh` copies and sanitizes your host agent configs into an isolated per-container temp directory. Nothing is shared between containers or written back to your host.

**Claude Code** — files picked up from host:

| Host path | What it contains | How it's used |
|---|---|---|
| `~/.claude.json` | Account metadata, MCP server configs (global + per-project) | Copied and sanitized: project paths remapped to container paths, `localhost` → `host.docker.internal`, hardware-dependent STDIO MCP servers rewritten to SSE |
| `~/.claude/settings.json` | Permission settings, tool allowlists | Copied as-is |
| `CLAUDE_CODE_OAUTH_TOKEN` env var | OAuth token (from `claude setup-token`) | Passed as env var — this is the actual auth credential |

**Codex** — files picked up from host:

| Host path | What it contains | How it's used |
|---|---|---|
| `~/.codex/config.toml` | Model settings, MCP server configs | Copied and sanitized: `localhost` → `host.docker.internal`, `[projects.*]` sections stripped (host paths don't exist in container) |
| `~/.codex/auth.json` | OAuth tokens (OpenAI + MCP servers) | Copied read-write (Codex refreshes tokens in place) |
| `<repo>/.codex/auth.json` | Project-specific OAuth tokens | Copied if present in mounted repos |

**MCP servers** in your config are handled based on type:
- **STDIO servers** with host-hardware dependencies (e.g., `trnscrb`): rewritten to SSE transport pointing to `host.docker.internal`
- **STDIO servers** that are pure API tools (e.g., `plane`): kept as-is (binary installed in image)
- **HTTP/SSE servers**: `localhost` URLs rewritten to `host.docker.internal`
- **Remote HTTP servers**: kept as-is (URL already points to remote endpoint)

To add a new MCP server that the harness should know about, configure it in your host's Claude Code or Codex config as normal. The harness picks it up automatically on next launch. If the server needs a new domain allowed through the firewall, add it to the relevant `profiles/*.conf` file and rebuild the image.

## Quick Start

```bash
# 1. Build the image
docker build -t agent-harness:latest .

# 2. Configure (see Configuration section below)
cp .env.example .env
# Edit .env with your paths and GitHub App credentials
# (harness.sh auto-sources .env — no need to source manually)

# 3. Launch a dev agent
./harness.sh dev \
  --project my-org/my-project \
  --repos ~/git/my-app:rw \
  --agent claude-code \
  --spec /cookbooks/my-org/my-project/PROJ-1-feature.md
```

## Configuration

Copy `.env.example` to `.env` and fill in your values. `harness.sh` auto-sources `.env` from its own directory — no need to source manually. Environment variables already set in your shell take precedence over `.env` values.

| Variable | Required | Description |
|---|---|---|
| `COOKBOOKS_PATH` | Yes | Path to your context/notes repo. Mounted at `/cookbooks` in the container. |
| `GITHUB_APP_ID` | No | GitHub App ID. Enables git push/pull (HTTPS) and `gh` CLI inside containers. |
| `GITHUB_APP_INSTALLATION_ID` | No | GitHub App Installation ID (from the org where the app is installed). |
| `GITHUB_APP_PEM` | No | Path to the GitHub App private key PEM file on your host. |

If GitHub App credentials are not set, the container will have no git push/pull or `gh` CLI access. This is fine for plan and review phases that only read repos.

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
  --spec /cookbooks/my-org/my-project/PROJ-1-feature.md
```

Default network profile: `python-dev`

For parallel execution across multiple specs/branches:

```bash
./harness.sh dev \
  --project my-org/my-project \
  --repos ~/git/my-app:rw ~/git/my-other-repo:rw \
  --agent codex \
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
  --spec <path>            Spec file path (dev phase, required)
  --branches <b1,b2,...>   Branches to review (review phase, required)
  --parallel               Enable parallel worktree execution (dev phase)
  --name <name>            Container name (default: harness-<phase>-<timestamp>)

ENVIRONMENT VARIABLES:
  COOKBOOKS_PATH                 Path to your context/notes repo (required)
  GITHUB_APP_ID                  GitHub App ID
  GITHUB_APP_INSTALLATION_ID     GitHub App Installation ID
  GITHUB_APP_PEM                 Path to GitHub App private key PEM file
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

## MCP Servers in Containers

The harness supports three strategies for making MCP servers available inside containers. `harness.sh` automatically sanitizes MCP configs when seeding the per-agent config directory.

### Strategy 1: In-Container STDIO

The MCP server binary is installed in the Docker image. Claude Code spawns it as a child process inside the container. No network access needed.

| Aspect | Detail |
|---|---|
| **Where it runs** | Inside the container |
| **Config type** | `"type": "stdio"` with `"command"` and `"args"` |
| **Image change** | Yes — install the package in the Dockerfile |
| **Network change** | None |
| **Example** | Plane (`uvx plane-mcp-server stdio`) |

**How to add a new STDIO MCP server:**
1. Add the package install to the Dockerfile (e.g., `uv tool install <package>`)
2. Rebuild the image
3. Add the server config to your `~/.claude.json` (global or project-level)
4. `harness.sh` copies the config into the container automatically

### Strategy 2: Host-Side HTTP/SSE

The MCP server runs on your host machine with HTTP/SSE transport. The container connects to it over the Docker bridge network via `host.docker.internal`.

| Aspect | Detail |
|---|---|
| **Where it runs** | On the host, as a separate process |
| **Config type** | `"type": "sse"` with `"url": "http://host.docker.internal:<port>/sse"` |
| **Image change** | None |
| **Network change** | None (host network is allowed by default) |
| **Example** | trnscrb (SSE on port 8001) |

**How `harness.sh` handles this:** If a STDIO MCP server in your config requires host hardware (e.g., audio capture), the sanitizer rewrites it to an SSE config pointing to `host.docker.internal`. Currently this is hardcoded for `trnscrb` — add new entries to the sanitizer in `harness.sh` as needed.

**Host-side prerequisites:**
1. The MCP server must support HTTP/SSE transport (not just STDIO)
2. It must be running on the host before launching the container
3. It must bind to `0.0.0.0` (or the Docker bridge IP) to accept container connections
4. DNS rebinding protection must allow `host.docker.internal` in the Host header

### Strategy 3: Remote HTTP

The MCP server is hosted remotely (cloud, staging environment). The container connects over the internet.

| Aspect | Detail |
|---|---|
| **Where it runs** | Remote server |
| **Config type** | `"type": "http"` with `"url"` pointing to the remote endpoint |
| **Image change** | None |
| **Network change** | Add the server's domain to the network profile |
| **Example** | your-remote-mcp (`https://your-mcp-server.example.com/mcp/`) |

**How to add a remote MCP server:**
1. Add the server config to your `~/.claude.json`
2. Add the server's domain to the relevant network profile(s) in `profiles/`
3. Rebuild the image (profiles are baked in), or hot-add at runtime: `docker exec -u root <container> allow-domain <domain>`
4. If the server requires OAuth, authenticate on the host first — tokens are mounted into the container

### Config Sanitization

`harness.sh` automatically transforms MCP configs when copying them into the container:

| Transformation | What it does |
|---|---|
| **Path remapping** | Project keys in `.claude.json` are remapped from host paths to container paths (e.g., `~/git/cookbooks` → `/cookbooks`) so Claude Code finds them in the correct working directory |
| **Localhost rewrite** | `localhost` and `127.0.0.1` in env vars and URLs are rewritten to `host.docker.internal` |
| **STDIO → SSE rewrite** | Hardware-dependent STDIO servers (trnscrb) are rewritten to SSE configs pointing to the host |
| **GitHub IP ranges** | When `github.com` is in the network profile, all GitHub CIDR ranges are fetched from the meta API and added to the allowlist (prevents IP rotation failures) |

## Credential Setup (One-Time)

### GitHub App (for git push/pull and `gh` CLI)

A GitHub App provides a single identity for all repos — no per-repo SSH deploy keys, no personal access tokens. The app generates short-lived installation tokens (~1 hour) that work for both `git` (over HTTPS) and the `gh` CLI.

**Step 1: Create the GitHub App**

1. Go to your GitHub org → **Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: `agent-harness` (must be globally unique)
   - **Homepage URL**: your org URL (required but not important)
   - **Webhook**: uncheck "Active"
3. **Repository permissions**:
   - Contents: Read and write
   - Pull requests: Read and write
   - Actions: Read-only
   - Metadata: Read-only (auto-selected)
4. **Where can this app be installed?**: "Only on this account"
5. Create the app

**Step 2: Note the App ID**

On the app's settings page after creation, copy the **App ID** (a number).

**Step 3: Generate a private key**

On the same page → **Private keys → Generate a private key**. A `.pem` file downloads:

```bash
mkdir -p ~/.config/harness
mv ~/Downloads/<app-name>.*.private-key.pem ~/.config/harness/github-app.pem
chmod 600 ~/.config/harness/github-app.pem
```

**Step 4: Install the app on your repos**

1. App settings → **Install App** (left sidebar)
2. Install on your org
3. Choose **Only select repositories** → pick the repos agents will work on
4. Install

**Step 5: Note the Installation ID**

After installing, the URL is `github.com/organizations/<org>/settings/installations/<ID>`. That number is the **Installation ID**.

**Step 6: Configure your `.env`**

```bash
GITHUB_APP_ID=<your app id>
GITHUB_APP_INSTALLATION_ID=<your installation id>
GITHUB_APP_PEM=~/.config/harness/github-app.pem
```

**How it works at runtime**: `harness.sh` mounts the PEM file read-only into the container and passes the app/installation IDs as env vars. Before the agent session starts, `github-auth.sh` runs as root: it creates a JWT signed with the PEM, exchanges it for a short-lived installation token via the GitHub API, and configures `git` (HTTPS) and `gh` with that token. The agent never sees the PEM — only the derived token.

**Token expiry**: Installation tokens expire after ~1 hour. For sessions longer than that, refresh from the host:

```bash
docker exec -u root <container-name> /usr/local/bin/github-auth.sh
```

### Claude Code / Codex auth

Authenticate on the host first — the harness mounts cached tokens into the container:

```bash
# Claude Code: run once, complete login
claude

# Codex: run once, complete login
codex
```

For OAuth-protected MCP servers, connect to them on the host first so the token is cached. The container uses the cached token; no browser flow runs inside the container.

### Why a GitHub App instead of SSH keys or PATs

| Approach | Drawbacks |
|---|---|
| **SSH deploy keys** | One key per repo (GitHub enforces uniqueness). Multiple repos = multiple keys + SSH config with host aliases. Operational burden scales with repos. |
| **Fine-grained PAT** | Scoped to repos and permissions, but it's a long-lived token tied to your personal account. If leaked, it's your identity. Must be stored in a `gh` config file. |
| **GitHub App** | One identity across all installed repos. Short-lived tokens (~1h). Permissions scoped at the app level. PEM stays on host (mounted read-only). If the token leaks, it expires in an hour. |

The GitHub App approach is the recommended mechanism for this harness. SSH keys and PATs work but require more configuration and have weaker security properties.

## Codex-Specific Notes

### Auth

Codex stores OAuth tokens in `~/.codex/auth.json` (file-based, not Keychain like Claude Code). The harness mounts this file **read-write** so token refresh works inside the container. Authenticate on the host first:

```bash
codex   # Complete login
```

### OAuth MCP Servers

For OAuth-protected MCP servers, authenticate on the host first:

```bash
codex mcp login <server-name>
```

The cached tokens in `~/.codex/auth.json` are mounted into the container. The server's domain must be in the network allowlist — either add it to a profile and rebuild, or hot-add at runtime:

```bash
docker exec -u root <container> allow-domain your-mcp-server.example.com login.microsoftonline.com
```

### Config Format

Codex uses TOML (`~/.codex/config.toml`), not JSON. The harness sanitizes it with `sed` (rewriting `localhost` → `host.docker.internal`), not a full TOML parser. Complex config transformations may need manual adjustment.

### Sandbox Interaction

Codex has its own OS-level sandbox (Seatbelt on macOS, Landlock on Linux). Inside a Docker container, the container itself is the sandbox boundary. Codex's sandbox adds defense-in-depth but is not required — the container already restricts filesystem and network access.

## How It Works

`harness.sh` does the following:

1. Creates a per-agent temp config directory, seeded from host credentials (read-only copy)
2. Starts the container **detached** (`sleep infinity`)
3. Initializes the firewall **as root** via `docker exec -u root` with the selected network profile
4. If firewall init fails, stops the container and exits (**fail-closed** — never runs without network isolation)
5. Runs `github-auth.sh` as root — exchanges PEM for a short-lived installation token, configures `git` and `gh`
6. Attaches an interactive session **as the `agent` user** via `docker exec -it -u agent`
7. On exit: stops the container, cleans up the temp config directory

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

## Known Limitations

### Clipboard image paste doesn't work in containers

Claude Code's image paste (Ctrl+V with a screenshot) reads from the macOS clipboard API, which is not available inside Docker containers — even through VS Code Remote Containers. The clipboard is an OS-level resource that doesn't cross the container boundary.

**Workaround: `harness-paste.sh`**

A helper script bridges the gap by saving the clipboard image to a shared mount point and copying the container-relative path to your clipboard:

1. Take a screenshot: **Cmd+Shift+4** (select region → copies to clipboard)
2. Run the paste script (via keyboard shortcut or manually):
   ```bash
   ~/git/agent-harness-v0/scripts/harness-paste.sh
   ```
3. A macOS notification shows the container path
4. The container path is now in your clipboard: `/cookbooks/.harness-images/paste-<timestamp>.png`
5. In the container terminal: type `@` then **Cmd+V** to paste the path

The image is saved to `$COOKBOOKS_PATH/.harness-images/` which is bind-mounted at `/cookbooks/.harness-images/` in every container. The path is identical across all three modes.

**Setting up a keyboard shortcut (macOS Automator):**

1. Open **Automator** → New → **Quick Action**
2. Set "Workflow receives" to **no input** in **any application**
3. Add action: **Run Shell Script**
4. Shell: `/bin/bash`
5. Script: full path to `harness-paste.sh` (e.g., `/Users/you/git/agent-harness-v0/scripts/harness-paste.sh`)
6. Save as "Harness Paste"
7. **System Settings → Keyboard → Keyboard Shortcuts → Services** → find "Harness Paste" → assign a shortcut (e.g., **Ctrl+Shift+V**)

**Cleanup:** `.harness-images/` accumulates files over time. Periodically run:
```bash
rm ~/git/<your-context-repo>/.harness-images/*
```

The directory is gitignored — screenshots are never committed.

## Security

See [security-model.md](security-model.md) for the full security model, threat analysis, host network access considerations, and residual risks.
