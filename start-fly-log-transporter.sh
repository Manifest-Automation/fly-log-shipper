#!/bin/bash
# Joins the Tailscale tailnet, waits for the Grafana LGTM stack's OTLP endpoint, then runs Vector
# (vector-configs/vector.toml). The shipper has nowhere else to send logs, so a failed join, or an endpoint that doesn't
# answer within 120s, fails the boot and Fly restarts the machine.
#
# Same tailnet join as the apps' deploy/start-with-tailscale.sh (crosstalk-backend, magic-santa): a one-off ephemeral,
# preauthorized auth key minted at each boot from the shared Tailscale OAuth client (Fly secrets TS_OAUTH_CLIENT_ID and
# TS_OAUTH_CLIENT_SECRET), tailscaled in TUN mode (enable_tun in fly.toml), tag TS_ADVERTISE_TAG (fly.toml), whose
# tailnet policy reaches the observability host's OTLP port.
set -uo pipefail

log() { printf '[start-fly-log-transporter] %s\n' "$*" >&2; }
fail() { log "FATAL: $*"; exit 1; }

VECTOR_CONFIG=/etc/vector/vector.toml
# The sink's endpoint, from the config itself (sinks.loki protocol.uri)
OTLP_ENDPOINT=$(sed -n 's/^ *protocol.uri *= *"\([^"]*\)".*/\1/p' "$VECTOR_CONFIG" | head -1)
[[ -n "$OTLP_ENDPOINT" ]] || { log "FATAL: no protocol.uri in $VECTOR_CONFIG"; exit 1; }

mint_authkey() {
  local resp http access_token key
  resp=$(mktemp)
  http=$(curl -sS --max-time 10 -o "$resp" -w "%{http_code}" -X POST \
    -d "grant_type=client_credentials" \
    -u "${TS_OAUTH_CLIENT_ID}:${TS_OAUTH_CLIENT_SECRET}" \
    https://api.tailscale.com/api/v2/oauth/token)
  if [[ "$http" != "200" ]]; then
    log "OAuth token exchange returned HTTP ${http}: $(head -c 200 "$resp")"
    rm -f "$resp"
    return 1
  fi
  access_token=$(jq -r '.access_token // empty' < "$resp")
  rm -f "$resp"
  [[ -n "$access_token" ]] || { log "OAuth token endpoint returned no access_token"; return 1; }

  resp=$(mktemp)
  http=$(curl -sS --max-time 10 -o "$resp" -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":true,\"preauthorized\":true,\"tags\":[\"${TS_ADVERTISE_TAG}\"]}}},\"expirySeconds\":600,\"description\":\"${FLY_APP_NAME:-fly} boot\"}" \
    https://api.tailscale.com/api/v2/tailnet/-/keys)
  if [[ "$http" != "200" ]]; then
    log "auth key mint returned HTTP ${http}: $(head -c 200 "$resp")"
    rm -f "$resp"
    return 1
  fi
  key=$(jq -r '.key // empty' < "$resp")
  rm -f "$resp"
  [[ -n "$key" ]] || { log "auth key mint returned no key"; return 1; }
  printf '%s' "$key"
}

join_tailnet() {
  [[ -n "${TS_OAUTH_CLIENT_ID:-}" && -n "${TS_OAUTH_CLIENT_SECRET:-}" && -n "${TS_ADVERTISE_TAG:-}" ]] \
    || { log "TS_OAUTH_CLIENT_ID, TS_OAUTH_CLIENT_SECRET (Fly secrets) or TS_ADVERTISE_TAG unset"; return 1; }
  [[ -c /dev/net/tun ]] || { log "/dev/net/tun missing (enable_tun = true in fly.toml?)"; return 1; }

  log "starting tailscaled..."
  tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock 1>&2 &
  local i
  for i in $(seq 1 40); do
    [[ -S /var/run/tailscale/tailscaled.sock ]] && break
    sleep 0.5
  done
  [[ -S /var/run/tailscale/tailscaled.sock ]] || { log "tailscaled socket did not appear in 20s"; return 1; }

  local authkey hostname
  authkey=$(mint_authkey) || return 1
  hostname="fly-${FLY_APP_NAME:-log-shipper}-${FLY_MACHINE_ID:-noid}"
  hostname="${hostname:0:63}"
  # --accept-dns=false keeps Fly's resolver, which the NATS source's 6PN address needs
  timeout 30 tailscale up \
    --authkey="${authkey}" \
    --hostname="${hostname}" \
    --accept-routes \
    --accept-dns=false \
    --advertise-tags="${TS_ADVERTISE_TAG}" \
    || { log "tailscale up failed or timed out"; return 1; }
  log "joined the tailnet as ${hostname} (${TS_ADVERTISE_TAG}): $(tailscale ip -4 2>/dev/null | head -1)"
}

wait_for_endpoint() {
  local hostport host port deadline=$(( $(date +%s) + 120 ))
  hostport="${OTLP_ENDPOINT#*://}"
  hostport="${hostport%%/*}"
  host="${hostport%:*}"
  port="${hostport##*:}"
  while (( $(date +%s) < deadline )); do
    if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
      log "OTLP endpoint reachable at ${host}:${port}"
      return 0
    fi
    log "waiting for the OTLP endpoint at ${host}:${port}..."
    sleep 2
  done
  return 1
}

join_tailnet || fail "could not join the tailnet"
wait_for_endpoint || fail "OTLP endpoint ${OTLP_ENDPOINT} not reachable after 120s"
# Only tailscaled needs the OAuth client
unset TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET

exec vector -c "$VECTOR_CONFIG"
