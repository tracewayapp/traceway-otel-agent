<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Traceway%20Logo%20White.png" />
    <source media="(prefers-color-scheme: light)" srcset="Traceway%20Logo.png" />
    <img src="Traceway Logo.png" alt="Traceway Logo" width="200" />
  </picture>
</p>

<p align="center">
  <a href="https://tracewayapp.com">Website</a> · <a href="https://docs.tracewayapp.com">Docs</a>
</p>

# Traceway OTel Agent

A simple, pre-configured [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
distribution (built with [OCB](https://opentelemetry.io/docs/collector/custom-collector/))
that pulls host metrics every 60s and tails log files, then ships both to
**any OTLP/HTTP-compatible backend**. Runs as a background service via systemd,
launchd, or Windows Service.

**Built for** sysadmins, SREs, and platform engineers who want host
observability without compiling and tuning the upstream OpenTelemetry
Collector themselves. Vendor-agnostic on the receiving side — point it at
Traceway, a self-hosted Jaeger / Grafana stack, or any other OTLP/HTTP
endpoint by setting `TRACEWAY_ENDPOINT`.

> **Auth is Bearer-only.** Every request goes out with
> `Authorization: Bearer ${TRACEWAY_TOKEN}` and nothing else. Compatible
> with Traceway, Grafana Cloud (bearer token), Honeycomb, New Relic OTLP,
> and most other OpenTelemetry collectors. **Not** compatible out of the
> box with backends expecting Basic auth, custom API-key headers
> (`X-Api-Key`, `DD-API-KEY`, …), HMAC-signed requests, mTLS client certs,
> or AWS sigv4.
>
> **Looking for contributors here.** Adding a new auth mode is usually a
> small, well-scoped change — extend the `otlphttp` exporter config and add
> a couple of env vars in `install.sh` / `install.ps1`. If you need Basic,
> custom API-key headers, or mTLS support, open a PR — partial drafts are
> welcome and we'll review + merge promptly. Sigv4 and HMAC are bigger
> lifts (request-time signing, not a static header), so open an issue
> first and we'll sketch a design together. Either way, this is a
> deliberately small surface area and the kind of contribution we want.

**Design goals**

- **Easy to install** — one `curl | bash` line, no YAML to write.
- **Configured by default** — sane scrape interval, sane batching, sane retries.
- **Small surface area** — only the receivers/processors/exporters needed for host metrics + tailed logs are compiled in. Auditable in one sitting.

```bash
curl -fsSL https://install.tracewayapp.com/install.sh | TRACEWAY_TOKEN=<your-token> bash
```

This is a **host agent**, not an application SDK — for app traces and
in-process runtime metrics, use the per-language Traceway client.

## Install

All installers read the same env vars:

| Var                     | Default                                  | Purpose                                                       |
| ----------------------- | ---------------------------------------- | ------------------------------------------------------------- |
| `TRACEWAY_TOKEN`        | _(required)_                             | Project token. Sent verbatim as `Authorization: Bearer <token>` — the only auth mode this agent supports |
| `TRACEWAY_ENDPOINT`     | `https://cloud.tracewayapp.com/api/otel` | Override for self-hosted Traceway                             |
| `TRACEWAY_SERVICE_NAME` | `$(hostname)`                            | `service.name` resource attribute                             |
| `TRACEWAY_LOG_PATHS`    | _(unset)_                                | Comma-separated globs to tail. Enables logs pipeline when set |

### Linux (systemd) / macOS (launchd)

Requires `curl`, `tar`, `sudo` (or root). Tested on Ubuntu 20.04+, Debian 11+,
Amazon Linux 2/2023, RHEL/Alma/Rocky 8+, Fedora 38+, macOS 11+ (Intel + Apple Silicon).

```bash
curl -fsSL https://install.tracewayapp.com/install.sh | \
  TRACEWAY_TOKEN=<your-token> \
  TRACEWAY_SERVICE_NAME=api-prod-eu-1 \
  TRACEWAY_LOG_PATHS="/var/log/app/*.log,/var/log/nginx/access.log" \
  bash
```

Installs (`<cfg>` = `/etc/traceway-otel-agent` on Linux, `/usr/local/etc/traceway-otel-agent` on macOS):

| Path                                 | Contents                                                                                                                                                 |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/usr/local/bin/traceway-otel-agent` | Binary                                                                                                                                                   |
| `<cfg>/config.yaml`                  | Byte-for-byte copy of [`config/default.yaml`](config/default.yaml) — edit freely                                                                         |
| `<cfg>/logs-overlay.yaml`            | Only when `TRACEWAY_LOG_PATHS` is set — merged on top at startup                                                                                         |
| `<cfg>/token` _(mode 0600)_          | `EnvironmentFile` with `TRACEWAY_TOKEN` + friends                                                                                                        |
| service unit                         | `/etc/systemd/system/traceway-otel-agent.service` (hardened: `ProtectSystem`, `PrivateTmp`) or `/Library/LaunchDaemons/com.tracewayapp.otel-agent.plist` |

### Windows (PowerShell, admin)

Requires Windows Server 2019+ / Windows 10/11 (64-bit), PowerShell 5.1+.
**Run the terminal as Administrator.**

```powershell
$env:TRACEWAY_TOKEN = "<your-token>"
iwr -useb https://install.tracewayapp.com/install.ps1 | iex
```

Parameter form (no env vars):

```powershell
& ([scriptblock]::Create((iwr -useb https://install.tracewayapp.com/install.ps1).Content)) `
  -Token "<your-token>" -ServiceNameAttr "api-prod-eu-1" `
  -LogPaths "C:\logs\app\*.log,C:\ProgramData\nginx\logs\access.log"
```

Installs the binary to `C:\Program Files\TracewayOtelAgent\`, config to
`C:\ProgramData\TracewayOtelAgent\` (ACL: Admins + SYSTEM only), and
registers the `TracewayOtelAgent` service (auto-start; env vars stored in
the service's registry `Environment` key, readable only by `SYSTEM` +
`Administrators`).

### Manual install (air-gapped / custom init)

1. Download the archive for your OS/arch from [Releases](../../releases), verify sha256 against `checksums.txt` in the same release.
2. Extract: the archive contains the binary, `default.yaml` (the config), and `service/` templates.
3. Drop the binary on `$PATH` and run:

   ```bash
   TRACEWAY_TOKEN=<token> TRACEWAY_ENDPOINT=https://cloud.tracewayapp.com/api/otel \
   TRACEWAY_SERVICE_NAME=$(hostname) traceway-otel-agent --config=/path/to/default.yaml
   ```

4. Wire it up with your init system using `service/` as a starting point.

## Managing the service

| Platform | Status                                 | Restart                                                    | Follow logs                                                              |
| -------- | -------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------ |
| Linux    | `systemctl status traceway-otel-agent` | `systemctl restart traceway-otel-agent`                    | `journalctl -u traceway-otel-agent -f`                                   |
| macOS    | `launchctl list \| grep traceway`      | `launchctl kickstart -k system/com.tracewayapp.otel-agent` | `tail -f /var/log/traceway-otel-agent.log`                               |
| Windows  | `Get-Service TracewayOtelAgent`        | `Restart-Service TracewayOtelAgent`                        | `Get-EventLog -LogName Application -Source TracewayOtelAgent -Newest 20` |

Health check (all platforms): `curl http://127.0.0.1:13133/` → `200`.

**Upgrade**: re-run the installer with the same env vars — it redownloads
the latest release, replaces the binary + config, and restarts the service.
If you've edited `config.yaml`, pin a version with `TRACEWAY_VERSION=vX.Y.Z`
and diff before upgrading.

## What gets captured

### Host metrics (60s scrape interval)

| Metric                                           | Unit           | Notes                       |
| ------------------------------------------------ | -------------- | --------------------------- |
| `system.cpu.utilization`                         | `1`            | CPU % per state per core    |
| `system.cpu.load_average.{1m,5m,15m}`            | `1`            | Unix load averages          |
| `system.memory.{usage,utilization}`              | `By` / `1`     | Memory bytes / %            |
| `system.disk.{io,operations}`                    | `By` / `{ops}` | Per-device I/O              |
| `system.filesystem.{usage,utilization}`          | `By` / `1`     | Per-mount bytes / %         |
| `system.network.{io,packets,errors,connections}` | mixed          | Per-interface               |
| `process.{cpu.time,memory.usage,memory.virtual}` | mixed          | Per-process RSS / VSZ / CPU |

The agent captures the **machine**; language SDKs (e.g.
[`go-client`](https://go.tracewayapp.com)) capture the **process**. Run
both if you want both views.

### Logs (opt-in)

When `TRACEWAY_LOG_PATHS` is set, `filelogreceiver` tails matching files
from EOF and ships each line as an OTLP log record. No parsing by default —
the raw line becomes the body. Each record carries `log.file.path` and
`log.file.name`. For JSON/regex/multiline parsing, edit the installed
`logs-overlay.yaml` and add [operators](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/stanza/docs/operators/README.md).

### Resource attributes (every signal)

- `service.name` — from `TRACEWAY_SERVICE_NAME` or hostname. Required by Traceway.
- `host.{name,id,arch}`, `os.{type,description}` — from `resourcedetectionprocessor`.
- `cloud.{provider,region,account.id}` — auto-detected on EC2 / GCE / Azure VMs (Linux, macOS, Windows).

### Cadence, batching, retries

| Setting                    | Value                | Source                                                        |
| -------------------------- | -------------------- | ------------------------------------------------------------- |
| Metrics scrape             | 60s                  | `hostmetrics.collection_interval`                             |
| Log tail                   | continuous from EOF  | `filelog.start_at: end` (no backfill on restart)              |
| Batch flush                | 10s or 8192 points   | `batch.timeout` / `send_batch_size`                           |
| Export compression         | gzip                 | `otlphttp.compression`                                        |
| In-memory retry queue      | ~1000 batches        | `otlphttp.sending_queue` (default)                            |
| Retry backoff              | 5s → 30s exponential | `otlphttp.retry_on_failure.initial_interval` / `max_interval` |
| Max retry window per batch | 5 minutes            | `otlphttp.retry_on_failure.max_elapsed_time`                  |
| Memory guard               | 256 MiB              | `memory_limiter.limit_mib`                                    |

When Traceway is unreachable, batches retry for up to 5 minutes then drop;
new batches queue (≤1000) behind retries, oldest-first when full. **The
queue is in-memory** — an agent restart loses pending data. For durable
buffering open an issue (path: `file_storage` extension +
`sending_queue.storage`).

## How install works

```
  ┌──────────────────────────────────────────────────────────────┐
  │                  install.tracewayapp.com                     │
  │        (Cloudflare Pages, deployed from site/ on main)       │
  └────────────────────────────┬─────────────────────────────────┘
                               │ curl | bash
                               ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                 install.sh / install.ps1                     │
  │   1. detect os/arch                                          │
  │   2. GET github.com/.../releases/download/vX.Y.Z/*.tar.gz    │
  │   3. verify sha256 against checksums.txt                     │
  │   4. copy default.yaml → config.yaml                         │
  │      (+ logs-overlay.yaml if TRACEWAY_LOG_PATHS is set)      │
  │   5. register systemd / launchd / Windows service            │
  └────────────────────────────┬─────────────────────────────────┘
                               │
                               ▼
                  traceway-otel-agent (running)
             ──▶  hostmetrics + filelog (opt-in)  ──▶
           OTLP/HTTP → https://cloud.tracewayapp.com/api/otel
                         (Bearer $TRACEWAY_TOKEN)
```

Installed `config.yaml` is a byte-for-byte copy of
[`config/default.yaml`](config/default.yaml); the logs overlay (only when
`TRACEWAY_LOG_PATHS` is set) is merged on top at startup via a second
`--config=` flag. The Bearer token never hits process listings — stored in
a mode-0600 `EnvironmentFile` (Linux), inlined in a root-owned plist
(macOS), or in the service's registry `Environment` key (Windows).

## Uninstall

Linux / macOS:

```bash
curl -fsSL https://install.tracewayapp.com/uninstall.sh | bash
```

Windows (admin PowerShell):

```powershell
Stop-Service TracewayOtelAgent; sc.exe delete TracewayOtelAgent
Remove-Item -Recurse -Force 'C:\Program Files\TracewayOtelAgent', 'C:\ProgramData\TracewayOtelAgent'
```

Stops + removes the service, binary, and config directory. Your Traceway
project is untouched.

## Development & testing

```bash
# OpenTelemetry Collector Builder, pinned to match builder-config.yaml.
go install go.opentelemetry.io/collector/cmd/builder@v0.116.0

# Optional linters — `make lint` skips them gracefully if absent.
brew install shellcheck       # or: apt-get install shellcheck
pip install --user yamllint

# Everything runs through the Makefile.
make build         # OCB → ./dist/traceway-otel-agent
make validate      # `collector validate ./config/default.yaml` with placeholder env
make lint          # bash -n + shellcheck + yamllint
make test-e2e      # layer 2 — in-process integration (~20s)
make test-install  # layer 3 — end-to-end install in systemd Ubuntu container (~60s, needs Docker)
make test-local    # validate + lint + test-e2e — the pre-push sanity sweep
make clean
```

Three test layers, each catching a different class of regression:

| Layer | Entry point                   | Time  | Catches                                                                                                   |
| ----- | ----------------------------- | ----- | --------------------------------------------------------------------------------------------------------- |
| 1     | `make validate` + `make lint` | < 10s | OCB manifest doesn't resolve; config syntax errors; shell/YAML/PowerShell bugs                            |
| 2     | `make test-e2e`               | ~20s  | Exporter doesn't ship data; wrong Bearer header; `service.name` missing; expected host metrics missing    |
| 3     | `make test-install`           | ~60s  | `install.sh` download / checksum / systemd wiring breaks; service fails to boot; no metrics after install |

**Layer 2** runs the OCB-built collector against **the real
`config/default.yaml`**, merged on top of a small
`tests/e2e/testdata/fast-overlay.yaml` (2s scrape interval, no cloud
detectors). Drift between the shipped config and asserted behavior fails
the test. The mock OTLP/HTTP receiver (`tests/mockotlp/`) records every
request and surfaces decoded metrics + headers for assertions.

**Layer 3** builds `mockotlp` for `linux/amd64`, packages
`dist/traceway-otel-agent` + `config/default.yaml` into a fake release
tarball with matching `checksums.txt`, runs a systemd-enabled Ubuntu
container (`--privileged --cgroupns=host`), execs `bash install.sh` against
`TRACEWAY_RELEASES_URL=file:///fixture`, and asserts metrics actually flow
through the mock. Needs cgroups v2 — won't work cleanly on macOS Docker
Desktop; use CI or a Linux VM.

### CI / release

`ci.yml` runs on every PR and push to `main`: `build` → artifact → `lint` +
`test-e2e` + `test-install` in parallel. All four must pass to merge.

Release is automatic — tag `vX.Y.Z` → `release.yml` builds five platform
archives + `checksums.txt` → GitHub Release → `publish-install.yml` bumps
the version pinned in `site/install.sh` and redeploys Cloudflare Pages.
Required repo secrets: `CLOUDFLARE_API_TOKEN` (scoped to the
`traceway-otel-agent-install` Pages project), `CLOUDFLARE_ACCOUNT_ID`.

### Troubleshooting

- **`make build` fails with "builder: command not found"**: install OCB
  (`go install go.opentelemetry.io/collector/cmd/builder@v0.116.0`) and
  make sure `$(go env GOPATH)/bin` is on `PATH`.
- **`make test-e2e` hangs or times out**: usually port 13133 is already in
  use by another collector on the host. The test prints the collector's
  stdout/stderr on failure.
- **`make test-install` fails with "systemd did not become ready"**: host
  needs cgroups v2 (`cat /proc/filesystems | grep cgroup2`). On macOS Docker
  Desktop this doesn't work cleanly — run it in CI or a Linux VM.
- **`make test-install` passes but no metrics arrive**: `docker exec <cid>
journalctl -u traceway-otel-agent` inside the container. Usually an
  env-substitution error — the mock URL wasn't substituted into `endpoint:`.
- **OCB build fails with dep resolution errors**: `builder-config.yaml`
  pins every component to the same `otelcol_version`; bump them together.
  Check release notes at https://github.com/open-telemetry/opentelemetry-collector-releases.

### Adding new tests

- **More host metric assertions**: extend the `expected` map in `tests/e2e/agent_e2e_test.go`.
- **Logs pipeline test**: parallel to `TestAgent_ExportsHostMetrics` — add a
  filelog-enabled overlay to `tests/e2e/testdata/`, write a file before the
  collector starts, assert `mock.Logs()` is non-empty and
  `mock.LogsHeaders()` has the expected `Authorization` header.
- **Upgrade path**: run `tests/install/run.sh` twice inside the same
  container and assert the service stays healthy.

Keep tests isolated — each test brings its own mock, its own config
overlay, and its own `TRACEWAY_SERVICE_NAME` so parallel runs don't clobber
each other.

To point at an embedded local Traceway for development, see [`traceway/examples/embedded-backend-otel/main.go`](https://github.com/tracewayapp/traceway/tree/main/examples/embedded-backend-otel) for a minimal backend you can stand up in one command.

## What's NOT in this agent

- **No Docker image / K8s manifests** — pods should use the OTel SDK in-process.
- **No traces pipeline** — your app's SDK does spans.
- **No log parsing by default** — ship raw lines, add operators when you need structure.
- **No auto-update** — re-run the installer. Boring, predictable, no 3am surprises.

## License

TBD.
