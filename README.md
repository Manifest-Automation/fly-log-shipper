# fly-log-shipper (manifest-log-shipper)

Ships the `manifest-automation` Fly organisation's logs to our self-hosted Grafana LGTM stack (Loki), over OTLP on the
Tailscale tailnet. Forked from [superfly/fly-log-shipper](https://github.com/superfly/fly-log-shipper); the upstream
provider sinks are gone: Loki is the only destination. Background and the rest of the observability setup:
`manifest_infrastructure` `docs/observability/README.md`.

## What it does

1. `start-fly-log-transporter.sh` joins the tailnet (an ephemeral, preauthorized auth key minted at each boot from
   the shared Tailscale OAuth client, tag `tag:fly-app-prd`, tailscaled in TUN mode), waits for the OTLP endpoint and
   runs Vector. A failed join or an unreachable endpoint fails the boot.
2. Vector (`vector-configs/vector.toml`) reads every log event of the organisation from Fly's NATS server.
3. It leaves out what Loki already has: the apps ship their log records themselves over OTLP and print them on stdout
   as JSON (Magic Max and Manifest Agents also a second time in the OpenTelemetry plain format). It keeps Fly's
   events (machine exits, OOM kills, health checks), tailscaled, gunicorn/uvicorn, start scripts, release commands
   and tracebacks.
4. It sends them as OTLP (protobuf, batched) to `http://100.112.89.83:4318/v1/logs`.

In Loki: `{service_name="fly"}`, with `service_namespace` of the app's product (`crosstalk`, `magic-santa`,
`magic-max`, `manifest`, else `fly`), `deployment_environment="production"`, `service_instance_id` = the Fly machine,
and the structured metadata `fly_app_name`, `fly_process_group`, `fly_region`, `fly_event_provider`, `fly_log_level`.
The lines carry no severity, so they never count toward the error alerts. For example, a product's machine events and
crashes: `{service_namespace="crosstalk", service_name="fly"} | fly_event_provider != "app"`.

## Configuration

| | |
|---|---|
| `ACCESS_TOKEN` | Fly token for the NATS source (secret); the start script hands it to Vector as a file (`/run/vector-secrets`) |
| `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET` | The shared Tailscale OAuth client (secrets; AWS Secrets Manager `manifest-agents-prd-tailscale-oauth`) |
| `TS_ADVERTISE_TAG` | Tailscale tag (fly.toml) |

Vector 0.61 does not expand environment variables in its configuration (only with
`--dangerously-allow-env-var-interpolation`), so the organisation (`manifest-automation`), the NATS address and subject,
the OTLP endpoint and `deployment_environment="production"` are written out in `vector-configs/vector.toml`.

Vector's own metrics are on `:9598/metrics` (fly.toml `[metrics]`).

## Changing it

```
mkdir -p /tmp/vs && printf x > /tmp/vs/access_token
docker run --rm -v $PWD:/w -w /w -v /tmp/vs:/run/vector-secrets timberio/vector:<version>-debian validate --no-environment vector-configs/vector.toml
docker run --rm -v $PWD:/w -w /w -v /tmp/vs:/run/vector-secrets timberio/vector:<version>-debian test vector-configs/vector.toml tests/vector_test.toml
fly deploy -a manifest-log-shipper
```

Use the version the Dockerfile pins. After a deploy, check `fly logs -a manifest-log-shipper` (tailnet joined, no sink
errors) and `{service_name="fly"}` in Grafana.
