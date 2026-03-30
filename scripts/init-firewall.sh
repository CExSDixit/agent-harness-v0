#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Agent Harness v0 — Firewall initialization
# Based on Anthropic's claude-code devcontainer init-firewall.sh
# Supports network profiles and hot-reload via ipset
#
# Usage: init-firewall.sh [profile-name]
# Profiles are loaded from /etc/harness/profiles/<name>.conf
# Special profile: "permissive" — allows all outbound except host network

PROFILE="${1:-default}"
PROFILE_FILE="/etc/harness/profiles/${PROFILE}.conf"

if [[ ! -f "$PROFILE_FILE" ]]; then
  echo "ERROR: Network profile not found: $PROFILE_FILE"
  echo "Available profiles:"
  ls /etc/harness/profiles/*.conf 2>/dev/null | xargs -I{} basename {} .conf
  exit 1
fi

echo "[firewall] Loading profile: $PROFILE"

# 1. Preserve Docker DNS rules before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true)

# Flush existing rules
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
ipset destroy allowed-domains 2>/dev/null || true

# 2. Restore Docker DNS resolution
if [[ -n "$DOCKER_DNS_RULES" ]]; then
  echo "[firewall] Restoring Docker DNS rules"
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | while read -r rule; do
    iptables -t nat $rule 2>/dev/null || true
  done
fi

# 3. Base rules: DNS and localhost
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 4. Allow host network (Docker bridge) — needed for:
#    - VS Code devcontainer server-client communication
#    - MCP servers running on the host (trnscrb, Plane, etc. via host.docker.internal)
#    - DNS forwarding fallback (Docker embedded DNS → host resolver)
HOST_IP=$(ip route 2>/dev/null | grep default | cut -d" " -f3 || true)
if [[ -n "$HOST_IP" ]]; then
  HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
  echo "[firewall] Allowing host network: $HOST_NETWORK"
  iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
  iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# 5. Branch based on profile type
if [[ "$PROFILE" == "permissive" ]]; then
  # --- Permissive mode: allow all outbound internet (host already blocked above) ---
  echo "[firewall] WARNING: Permissive mode — all outbound internet traffic allowed"

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  # Allow established inbound (responses to outbound requests)
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  echo "[firewall] Profile 'permissive' active. All outbound allowed, host network blocked."

else
  # --- Allowlist mode: only ipset members allowed ---

  # Create ipset for allowed domains
  ipset create allowed-domains hash:net

  # Load domains from profile
  echo "[firewall] Resolving domains from profile..."
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    domain=$(echo "$line" | xargs)  # trim whitespace

    ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')
    if [[ -z "$ips" ]]; then
      echo "[firewall] Warning: could not resolve $domain"
      continue
    fi

    while read -r ip; do
      if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        ipset add allowed-domains "$ip" 2>/dev/null || true
        echo "[firewall] Added $ip ($domain)"
      fi
    done <<< "$ips"
  done < "$PROFILE_FILE"

  # If github.com or api.github.com is in the profile, fetch all GitHub CIDR ranges
  # GitHub uses Anycast — DNS returns different IPs on each resolution.
  # The meta API provides all possible IP ranges for web, API, and git traffic.
  if grep -qE "^(github\.com|api\.github\.com)$" "$PROFILE_FILE" 2>/dev/null; then
    echo "[firewall] Fetching GitHub IP ranges from meta API..."
    GH_META=$(curl -sf --connect-timeout 10 https://api.github.com/meta 2>/dev/null || true)
    if [[ -n "$GH_META" ]]; then
      echo "$GH_META" | jq -r '(.web + .api + .git + .packages + .actions)[]' 2>/dev/null | while read -r cidr; do
        # Only add IPv4 CIDRs
        if [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
          ipset add allowed-domains "$cidr" 2>/dev/null || true
        fi
      done
      GH_COUNT=$(echo "$GH_META" | jq -r '(.web + .api + .git + .packages + .actions)[]' 2>/dev/null | grep -c "^[0-9]" || echo 0)
      echo "[firewall] Added $GH_COUNT GitHub CIDR ranges"
    else
      echo "[firewall] Warning: could not fetch GitHub meta (api.github.com may not be resolved yet)"
    fi
  fi

  # Set default policies
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP

  # Allow established connections
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # Allow only ipset members
  iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

  # Reject everything else (immediate feedback, not silent drop)
  iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

  echo "[firewall] Profile '$PROFILE' active. $(ipset list allowed-domains 2>/dev/null | grep -c "^[0-9]") IPs allowed."
  echo "[firewall] Use 'allow-domain <domain>' to add domains at runtime."
fi
