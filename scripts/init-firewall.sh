#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Agent Harness v0 — Firewall initialization
# Based on Anthropic's claude-code devcontainer init-firewall.sh
# Supports network profiles and hot-reload via ipset
#
# Usage: init-firewall.sh [profile-name]
# Profiles are loaded from /etc/harness/profiles/<name>.conf

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

# 3. Allow DNS and localhost before restrictions
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 4. Create ipset for allowed domains
ipset create allowed-domains hash:net

# 5. Load domains from profile
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

# 6. Allow host network (for Docker bridge communication)
HOST_IP=$(ip route 2>/dev/null | grep default | cut -d" " -f3 || true)
if [[ -n "$HOST_IP" ]]; then
  HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
  echo "[firewall] Allowing host network: $HOST_NETWORK"
  iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
  iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# 7. Set default policies
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
