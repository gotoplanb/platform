# Observability

How telemetry flows out of Watch, where it lands, and how it's operated. The **why** is
[ADR-016](../../../watch/watch-adrs.md) (topology), ADR-018 (platform plane), and ADR-019
(warm-standby); this doc is the **how**.

> One-line mental model: **the app knows nothing about its backend.** It emits OTLP to a
> localhost collector; *where telemetry goes is an IaC decision per environment*, never an app
> setting. Swapping Tempo → Datadog is a collector-config change with **no app redeploy**.

---

## 1. The three hops

```
┌─ ECS task ───────────────────────────────┐
│  app (Django, OTEL SDK)                   │        per-env Alloy gateway            destination
│     │ OTLP → http://localhost:4318        │       (ECS Fargate, Cloud Map)
│     ▼                                      │      ┌────────────────────────┐
│  alloy sidecar  ──OTLP gRPC :4317─────────┼─────▶│ receive → [tail-sample] │──▶  staging: Tempo (traces)
│  (essential=false)                         │      │  → batch → export       │     prod:    Grafana Cloud
└────────────────────────────────────────────┘      └────────────────────────┘             (traces+metrics+logs)
   gateway.<env>.svc:4317  (Cloud Map A record)
```

1. **App → sidecar.** The app always exports to `http://localhost:4318` (an Alloy sidecar in the
   same task). It carries only `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=<env>,service.version=<git-sha>`
   — no endpoint, no vendor, no credentials. The sidecar is `essential=false`: if telemetry is
   down, the app is not.
2. **Sidecar → gateway.** The sidecar forwards over gRPC to the per-env gateway, discovered via
   Cloud Map at `gateway.<env>.svc:4317`. The sidecar does nothing clever — batching, sampling,
   and credentials live at the gateway, not sprayed across every task.
3. **Gateway → destination.** One shared collector per env batches, (optionally) tail-samples
   traces, and exports to the env's backend. **This last hop is the only per-env difference.**

Everything is Terragrunt/OpenTofu in the watch account (`614933206631`, us-east-1).

---

## 2. The shared Alloy renderer (`modules/alloy`)

One module renders the River config for **both** roles, so staging and prod share the shape and
only the last hop differs. Inputs decide the behavior:

| Input | Effect |
|---|---|
| `role = "sidecar"` | receive on localhost, forward to the gateway |
| `role = "gateway"` | receive from sidecars, batch, export; may tail-sample |
| `forward_endpoint` | in-VPC gRPC target (the Tempo slice) |
| `vendor_endpoint` + `vendor_auth_header_env` | managed vendor over OTLP/HTTP + `Authorization` header (Grafana Cloud) |
| *(neither endpoint set)* | **debug sink** — so the pipeline is valid + verifiable before a backend exists |
| `tail_sampling` | enable the incident-tuned policy (§5) |
| `dest_traces_only` | drop metrics + logs at the receiver (for a traces-only backend, §4) |

**Exporter precedence:** vendor (OTLP/HTTP + TLS) → in-VPC gRPC (plaintext, SG-scoped) → debug
sink. The vendor token is never in the config text — Alloy reads the `Authorization` header from
an env var (`sys.env`), fed by the task's `secrets` block.

Config is delivered **env→file** (the entrypoint writes `$ALLOY_CONFIG` to a file and runs
`alloy run … --stability.level=experimental`) — no custom image. The experimental flag is needed
for the debug sink and tail-sampling.

---

## 3. The gateway (`modules/gateway`)

A per-env Alloy collector as an ECS Fargate service:

- **Own ECS cluster + Cloud Map** private DNS namespace `watch-<env>.svc`; the service registers
  as `gateway.watch-<env>.svc` so sidecars resolve it (15s TTL A records).
- **SG**: only the app SG may reach `:4317/:4318`. Egress open (to reach a vendor via NAT).
- **Networking follows the env profile** (ADR-015): `ha`/private-subnets+NAT for prod; the
  gateway can't pull its image or reach a vendor without one of NAT-or-public-IP, so it must
  match the env.
- **Vendor token as TF-managed SecureString**: `vendor_auth_header` (sensitive var) → an
  `aws_ssm_parameter` SecureString → the task `secrets` block → `sys.env("VENDOR_OTLP_AUTH")`.
  Never an imperative `aws ssm put-parameter`; `has_vendor_token` is `nonsensitive()` so the
  sensitivity doesn't force spurious task-def churn.
- **Warm-minimal**: `desired_count` has `ignore_changes`, so it can be scaled to 0 when idle and
  back to 1 without Terraform fighting.

---

## 4. Backends, per environment

### Staging → the in-AWS Tempo slice (`modules/tempo` + `modules/grafana`)

The "Watchtower slice," rewritten from the `~/watchtower` draft to align with platform (env→file
config, no baked images / S3 / EFS / VPC peering):

- **`modules/tempo`** — Grafana Tempo on Fargate; its distributor accepts OTLP directly on
  `:4317/:4318`, stores traces locally (warm-minimal — no S3), serves the query API on `:3200`.
  Owns the shared obs cluster + Cloud Map namespace `watch-obs.svc` (Grafana reuses them).
- **`modules/grafana`** — Grafana on Fargate behind a small public ALB, with the Tempo datasource
  provisioned; admin password generated into SSM.
- **Co-located in the staging VPC** (both staging and the slice are warm-standby now) → no VPC
  peering. This is a deviation from ADR-018's separate-platform-account vision, accepted as the
  single-account DEBT applied to the platform plane; the account seam is preserved.

**Tempo is traces-only.** The app also emits metrics + logs; Tempo rejects them
(`Unimplemented … LogsService/MetricsService`). So the staging gateway sets **`dest_traces_only`**
to drop metrics + logs at the receiver rather than export-and-fail.

### Prod → Grafana Cloud (managed vendor)

Per ADR-016 §2 / ADR-018: **product prod never depends on the Watchtower slice.** The prod gateway
exports to Grafana Cloud (full LGTM — traces→Tempo, metrics→Mimir, logs→Loki), so
`dest_traces_only` stays **false**.

Credentials come from `~/platform/.env` (one private place) and are read by
`prod/gateway/terragrunt.hcl` via `get_env()` — exactly what Grafana Cloud's OTLP connection
emits:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT="https://otlp-gateway-prod-<zone>.grafana.net/otlp"
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic%20<base64>"   # base64 = instanceID:token
```

The header is **URL-encoded** per the OTel spec — terragrunt strips `Authorization=` and turns
`%20` back into a space → `Basic <base64>`, stored as the SecureString the gateway sends as an
OTLP request header. Rotating creds = regenerate in Grafana, update `.env`, re-apply.

---

## 5. Tail-sampling — incident-tuned (#23, ADR-016 §3)

Tail-sampling needs to see the **whole** trace, which a per-task sidecar can't — this alone
justifies the gateway. The policy is tuned for an incident tool: a trace is **kept if it matches
any** policy; only boring reads are sampled.

| Policy | Keeps | Why |
|---|---|---|
| `errors` | any span with status ERROR | never lose a failure during a postmortem |
| `slow` | trace over the latency floor (default 1s) | the ones you investigate |
| `writes` | `http.method` ∈ POST/PUT/PATCH/DELETE | **every ack / escalate / resolve / intake** — state transitions are the whole point of an incident tool |
| `reads` | probabilistic slice (default 10%) | health checks, status page, list/detail GETs |

Enabled on **both** gateways (staging rehearses prod). Traces route through the sampler; metrics +
logs bypass it. **Verified on staging**: in a 34s window, 6/6 POST writes kept, 4/50
`GET /api/health` kept (~8%).

---

## 6. Cost model — warm-standby (ADR-019 amendment)

Staging + the observability slice are kept **warm-minimal**, not destroyed between releases: they
serve continuous CI/CD (staging is the DAST + smoke gate target; the slice is its trace backend).
Cost is controlled by **scaling task counts down when idle** (`desired_count` carries
`ignore_changes`), not by `terragrunt destroy`. The full teardown/recreate loop still exists for a
clean slate.

Rough footprint when warm: gateway + Tempo + Grafana ≈ a few small Fargate tasks + a small ALB.

---

## 7. Operating it

**Confirm the vendor creds (no traffic needed):**
```bash
set -a; . ./.env; set +a
AUTH="${OTEL_EXPORTER_OTLP_HEADERS#Authorization=}"; AUTH="${AUTH//\%20/ }"
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$OTEL_EXPORTER_OTLP_ENDPOINT/v1/traces" \
  -H "Authorization: $AUTH" -H 'content-type: application/json' --data '{"resourceSpans":[]}'
# 200 = creds good · 401 = auth wrong
```

**Query traces (staging Tempo, via Grafana's datasource proxy):**
```bash
curl -s -u admin:$PW \
  "$GRAFANA/api/datasources/proxy/uid/$DS/api/search?q=%7B%20resource.service.name%20%3D%20%22watch-backend%22%20%7D&limit=20"
```
…or open Grafana → Explore → Tempo → TraceQL `{ resource.service.name = "watch-backend" }`.

**Validate an Alloy config change before deploying** (compact one-line policy blocks are invalid
River — see gotchas):
```bash
docker run --rm -v "$PWD:/c" grafana/alloy validate --stability.level=experimental /c/config.alloy
```

**Scale a gateway to 0 when idle** (Terraform won't fight it):
```bash
aws ecs update-service --cluster watch-<env>-gateway --service watch-<env>-gateway --desired-count 0
```

---

## 8. Gotchas (learned the hard way)

- **River needs one attribute per line.** `policy { name = "x" type = "y" }` fails with
  `expected TERMINATOR, got IDENT`. Multi-line the blocks. Validate against the real
  `grafana/alloy` binary — `tofu console` renders the *string* fine but doesn't parse River.
- **Tempo is traces-only.** Sending it metrics/logs → `Unimplemented`, dropped, error spam. Use
  `dest_traces_only` for a traces-only backend; a full LGTM/vendor takes all three signals.
- **Grafana Cloud's OTLP header is URL-encoded** (`Basic%20…`). Decode `%20`→space before use.
- **The app carries no vendor name, ever.** If you're tempted to put an endpoint in the app's env,
  stop — it goes at the gateway (ADR-016).
- **Prod traces need a promotion.** The prod app's running tasks only start forwarding to the
  gateway after CodeDeploy rolls the gateway-forwarding task def — i.e. a prod deploy.
