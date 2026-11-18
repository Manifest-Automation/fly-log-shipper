# Vector reads the organisation's Fly logs from NATS and sends them to the self-hosted Grafana LGTM stack's OTLP
# endpoint (Loki) over the Tailscale tailnet (start-fly-log-transporter.sh). Pinned: the opentelemetry sink's otlp
# codec, with native batching, needs a current Vector.
FROM timberio/vector:0.61.0-debian

# Tailscale (the OTLP endpoint is only on the tailnet; fly.toml's enable_tun gives tailscaled /dev/net/tun), and curl/jq
# to mint its auth key
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates jq iptables iproute2 \
 && . /etc/os-release \
 && curl -fsSL "https://pkgs.tailscale.com/stable/debian/${VERSION_CODENAME}.noarmor.gpg" \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL "https://pkgs.tailscale.com/stable/debian/${VERSION_CODENAME}.tailscale-keyring.list" \
      -o /etc/apt/sources.list.d/tailscale.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends tailscale \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/lib/tailscale /var/run/tailscale

COPY vector-configs /etc/vector/
COPY ./start-fly-log-transporter.sh .
CMD ["bash", "start-fly-log-transporter.sh"]
ENTRYPOINT []
