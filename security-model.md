# Security Model — Agent Harness v0

## Threat model

The harness protects against an AI coding agent (Claude Code, Codex) that goes off-script — whether through prompt injection, malicious dependencies, or unexpected behavior. The host machine is trusted. The internet is not.

**In scope:**
- Agent reaches arbitrary internet endpoints (supply chain exfiltration, dependency phone-home)
- Agent reads files outside the intended repo scope (credentials, other projects, personal files)
- Agent mutates files outside the working directory
- Agent escalates privileges inside the container

**Out of scope (accepted risks):**
- Agent makes API calls as the user (Anthropic/OpenAI) — necessary for function
- Agent pushes to repos the GitHub App is installed on — necessary for dev workflow
- Agent reaches host-side MCP servers — necessary for tooling (Plane, trnscrb)

## Isolation layers

### Filesystem isolation

The agent only sees what is explicitly mounted:

| Mount | Mode | Purpose |
|---|---|---|
| Repo(s) | rw (dev) / ro (plan, review) | Code the agent works on |
| Cookbooks | rw | Specs, reports, prompts |
| GitHub App PEM | ro (root-only) | Derives short-lived tokens for git push/pull and gh CLI |
| Agent config dir | rw (per-agent temp copy) | Session state, not host config |
| Agent credentials | ro (seeded copy) | Auth tokens for Claude/Codex |

Everything else on the host is invisible to the container: `~/.aws`, `~/.ssh` (full keyring), `~/Documents`, other repos, other agent sessions.

### Network isolation

Outbound traffic is restricted to allowlisted domains via `iptables` + `ipset`. The firewall is initialized by the operator as root before the agent session starts. The agent cannot modify network policies.

| Profile | What's allowed |
|---|---|
| `default` | Agent APIs, GitHub, pypi, npm |
| `plan` | Default + documentation/research sites |
| `python-dev` | Default + Python ecosystem |
| `node-dev` | Default + Node ecosystem |
| `review-only` | Agent APIs + GitHub fetch only |
| `permissive` | All outbound internet (use sparingly) |

Network policies can be modified at runtime by the operator via `docker exec -u root` without restarting the container or interrupting the agent session.

### Process isolation

The agent runs as the unprivileged `agent` user:
- No sudo access (no sudoers entry for agent user)
- No root escalation path
- Cannot modify firewall rules, ipset, or iptables
- Cannot access `/proc` or `/sys` in ways that affect the host (standard container namespacing)

### Privilege separation

| Action | Who can do it | How |
|---|---|---|
| Initialize firewall | Operator (root) | `harness.sh` runs `docker exec -u root init-firewall.sh` before agent starts |
| Add/remove allowed domains | Operator (root) | `docker exec -u root <container> allow-domain <domain>` |
| Start agent session | Operator | `harness.sh` attaches via `docker exec -it -u agent` |
| Run code, git, install packages | Agent (unprivileged) | Normal container operation within mounted paths |
| Modify host files | Nobody | Host filesystem not mounted except explicit paths |

### Fail-closed behavior

If firewall initialization fails (missing NET_ADMIN capability, profile not found, iptables error), `harness.sh` stops the container and exits. The agent session never starts without network isolation in place.

## Host network access

The Docker bridge network (host ↔ container) is **allowed** in all profiles, matching Anthropic's reference implementation. This is required for:

1. **VS Code devcontainer communication** — the VS Code server inside the container talks to the VS Code client on the host over the Docker bridge
2. **Host-side MCP servers** — trnscrb (audio capture), Plane, and other STDIO/HTTP MCP servers running on the host are reachable via `host.docker.internal`
3. **DNS forwarding fallback** — Docker's embedded DNS (`127.0.0.11`) forwards to the host resolver. Some Docker setups (especially Docker Desktop on macOS) route this through the bridge gateway IP

### When host network access becomes an attack vector

**1. Services bound to `0.0.0.0` on the host.**
If a service on the host listens on all interfaces (not just `127.0.0.1`), the container can reach it via the Docker bridge. A compromised agent could scan the bridge subnet, find open ports, and interact with unintended services (local databases, admin dashboards, dev servers).
- **Mitigation:** Bind host services to `127.0.0.1` only. Docker bridge traffic comes from a different subnet (typically `172.17.0.0/24`), so it cannot reach `localhost`-bound services.

**2. Cloud instance metadata endpoints.**
On AWS, Azure, or GCP VMs, the instance metadata service at `169.254.169.254` is reachable from containers via the host network. A compromised agent could read IAM credentials, instance identity tokens, or other sensitive metadata.
- **Mitigation:** Explicitly block `169.254.169.254` in the firewall script if deploying on cloud infrastructure. Not a risk on a local Mac.
- **Status:** Not currently blocked (harness is designed for local macOS/Linux use). Add the block before deploying to cloud VMs.

**3. MCP servers as lateral movement.**
Host-side MCP servers with write capabilities (e.g., Plane's `create_work_item`, `delete_work_item`) can be invoked by a prompt-injected agent. This is the same risk as running agents on the host without the harness — but the harness makes the attack surface explicit.
- **Mitigation:** Configure MCP server tool permissions tightly (tool-level allow rules in `.claude/settings.local.json`). Only grant the minimum tools each phase needs.

**4. Docker socket mounting.**
The harness does **not** mount the Docker socket. If someone adds `-v /var/run/docker.sock:/var/run/docker.sock` to harness.sh, the agent gains full Docker API access and can spawn privileged containers, escaping all isolation.
- **Mitigation:** Never mount the Docker socket. This is enforced by harness.sh not including it, but there is no technical prevention if someone edits the script.

**5. Host-side MCP servers bound to 0.0.0.0.**
MCP servers running on the host with SSE/HTTP transport (e.g., trnscrb) may bind to `0.0.0.0` to accept connections from Docker containers. This exposes the server port to all devices on the local network.
- **What's exposed:** All MCP tools on that server. For trnscrb: transcript listing, transcript content, recording control.
- **What protects it:** MCP SDK DNS rebinding protection (rejects requests with unrecognized Host headers). MCP SSE handshake requirement (not a simple HTTP GET).
- **What doesn't protect it:** No authentication on SSE transport. No TLS. A purpose-built MCP client on the local network can connect.
- **Mitigation:** Bind to `127.0.0.1` (default) when harness containers aren't needed. Only use `0.0.0.0` during active harness sessions. Alternatively, bind to the Docker bridge subnet only (`172.17.0.0/24`) for tighter scoping.

**6. Multi-tenant / shared host.**
If multiple users share the same host, one user's container can reach another user's services via the host network. Not relevant for single-user use; becomes a concern if the harness is deployed on shared infrastructure.
- **Mitigation:** Use per-user Docker networks with isolated bridge subnets, or move to microVM isolation (Microsandbox, Firecracker).

## Credential handling

### What's exposed to the agent

| Credential | How exposed | Risk |
|---|---|---|
| Claude/Codex auth tokens | Mounted read-only from per-agent temp copy | Agent can make API calls as the user. Unavoidable. |
| GitHub App installation token | Configured in git/gh by `github-auth.sh` at startup | Agent can push/pull and create PRs on repos the app is installed on. Token expires in ~1 hour. |
| MCP OAuth tokens | Inside mounted config files | Agent can call OAuth-protected MCP servers. Token refresh handled silently. |

**Note on GitHub App credentials**: The PEM private key is mounted read-only at `/etc/harness/github-app.pem` and is only readable by root. The agent user cannot read the PEM directly — it only sees the derived installation token configured in git/gh. If the installation token is compromised, it expires in ~1 hour and is scoped to the app's permissions (Contents, Pull requests, Actions read-only, Metadata).

### What's NOT exposed

| Credential | Why not |
|---|---|
| GitHub App PEM private key | Mounted read-only, root-owned. Agent user cannot read it. |
| Personal SSH keyring (`~/.ssh/`) | Not mounted. Git uses HTTPS with GitHub App token, not SSH. |
| GitHub PATs | Not used. GitHub App replaces personal access tokens. |
| AWS/Azure/GCP credentials | `~/.aws/`, `~/.azure/`, `~/.config/gcloud/` not mounted |
| Browser cookies/sessions | Host browser state not accessible from container |
| Other agent sessions | Each agent gets its own temp config dir; sessions are not shared |
| Host Claude/Codex config | Per-agent copy is made; host originals are not mounted |

### MCP server attack surface by type

| MCP Type | Attack Surface | Mitigation |
|---|---|---|
| **In-container STDIO** (e.g., Plane) | Agent has full access to all tools the server exposes. If the server has write capabilities (create/delete tickets), a prompt-injected agent can use them. | Scope tool permissions in `.claude/settings.local.json`. Only grant the tools each phase needs. |
| **Host-side HTTP/SSE** (e.g., trnscrb) | Server port is exposed on host network. If bound to `0.0.0.0`, reachable from local network. No auth on MCP SSE transport. Agent can invoke all tools. | Bind to `127.0.0.1` when containers aren't needed. DNS rebinding protection limits Host headers. See section 5 above. |
| **Remote HTTP** (e.g., remote MCP server) | Agent can call the remote API with mounted OAuth tokens. Token scope determines blast radius. | Use narrowly-scoped OAuth tokens. Remote server's own auth/RBAC is the primary control. |

### Per-agent isolation

Each agent container gets its own temp directory seeded from host credentials:
- Credentials file: copied read-only (agent cannot modify the original)
- Session directory: writable but isolated (one agent cannot see another's sessions)
- Cleaned up on container exit by harness.sh

## Residual risks

These are accepted risks that the harness does not mitigate:

1. **Exfiltration to allowlisted domains.** A malicious dependency could encode stolen data in GitHub API calls, npm registry requests, or Anthropic API payloads. The network allowlist permits these domains by necessity.

2. **Kernel-level escape.** Docker containers share the host kernel. A kernel exploit inside the container could theoretically escape to the host. Mitigated by keeping Docker and the host OS updated. For stronger isolation, migrate to Microsandbox (microVM with its own kernel).

3. **Supply chain attack within allowed scope.** A typosquatted package from pypi.org installs successfully (pypi is allowlisted) and runs arbitrary code inside the container. The damage is limited to the mounted paths and allowlisted network, but the agent's repo mount and credentials are accessible.

4. **Prompt injection via repo content.** Malicious code in a reviewed repository could instruct the agent to take unexpected actions. The agent still has access to its mounted paths and allowed network endpoints. The harness limits blast radius but doesn't prevent the injection itself.

## Comparison to running on bare host

| Concern | Bare host | Harness |
|---|---|---|
| Agent reads `~/.aws/credentials` | Possible | Blocked (not mounted) |
| Agent reads `~/.ssh/id_rsa` | Possible | Blocked (SSH not used, no keys mounted) |
| Malicious dep phones home to attacker server | Unrestricted | Blocked (not in allowlist) |
| Agent writes to files outside repo | Possible | Blocked (only mounted paths visible) |
| Agent scans local network | Unrestricted | Allowed on host network only (Docker bridge) |
| Agent modifies firewall rules | N/A | Blocked (no sudo, no root access) |
| Agent installs crypto miner | Unrestricted outbound | Blocked (pool servers not in allowlist) |
