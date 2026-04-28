#!/usr/bin/env bash
# Traceway OTel Agent installer (Linux / macOS).
#
#   curl -fsSL https://install.tracewayapp.com/install.sh | TRACEWAY_TOKEN=<token> bash
#
# Required:
#   TRACEWAY_TOKEN          Traceway project token
# Optional:
#   TRACEWAY_ENDPOINT       OTLP/HTTP base URL (default https://cloud.tracewayapp.com/api/otel)
#   TRACEWAY_SERVICE_NAME   service.name resource attribute (default: $(hostname))
#   TRACEWAY_LOG_PATHS      Comma-separated globs to tail. Enables logs pipeline.
#   TRACEWAY_PROCESS_NAMES  Comma-separated process names (or `*` for all).
#                           Opts into per-process metrics. Off by default
#                           because cardinality scales with the host's
#                           process count.
#   TRACEWAY_VERSION        Override agent version (default: pinned at deploy time)
#   TRACEWAY_RELEASES_URL   Override release-archive base URL (default: GitHub Releases).
#                           Accepts file:// URLs for air-gapped / test installs.

set -eu

# __TRACEWAY_VERSION__ is replaced by .github/workflows/publish-install.yml
# when the script is deployed to install.tracewayapp.com.
DEFAULT_VERSION="__TRACEWAY_VERSION__"
VERSION="${TRACEWAY_VERSION:-$DEFAULT_VERSION}"

REPO="tracewayapp/traceway-otel-agent"
RELEASES="${TRACEWAY_RELEASES_URL:-https://github.com/${REPO}/releases/download}"

err() { printf 'traceway-install: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'traceway-install: %s\n' "$*"; }

case "$VERSION" in
  ""|__TRACEWAY_VERSION__|__NOT_RELEASED__)
    err "this installer has not been released yet. Check https://github.com/${REPO}/releases, then re-run with TRACEWAY_VERSION=vX.Y.Z."
    ;;
esac

[ -n "${TRACEWAY_TOKEN:-}" ] || err "TRACEWAY_TOKEN is required (your Traceway project token)"

ENDPOINT="${TRACEWAY_ENDPOINT:-https://cloud.tracewayapp.com/api/otel}"
SERVICE_NAME="${TRACEWAY_SERVICE_NAME:-$(hostname 2>/dev/null || echo traceway-host)}"
LOG_PATHS="${TRACEWAY_LOG_PATHS:-}"
PROCESS_NAMES="${TRACEWAY_PROCESS_NAMES:-}"

UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_S" in
  Linux)  OS="linux"  ;;
  Darwin) OS="darwin" ;;
  *) err "unsupported OS: $UNAME_S (Linux and macOS only; for Windows use install.ps1)" ;;
esac
case "$UNAME_M" in
  x86_64|amd64)  ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) err "unsupported arch: $UNAME_M" ;;
esac
log "detected $OS/$ARCH"

if [ "$OS" = "linux" ]; then
  BIN_DIR="/usr/local/bin"
  CONFIG_DIR="/etc/traceway-otel-agent"
  UNIT_PATH="/etc/systemd/system/traceway-otel-agent.service"
else
  BIN_DIR="/usr/local/bin"
  CONFIG_DIR="/usr/local/etc/traceway-otel-agent"
  PLIST_PATH="/Library/LaunchDaemons/com.tracewayapp.otel-agent.plist"
fi
BIN_PATH="${BIN_DIR}/traceway-otel-agent"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"
TOKEN_PATH="${CONFIG_DIR}/token"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || err "root required; install sudo or run as root"
  SUDO="sudo"
fi

TARBALL="traceway-otel-agent_${VERSION}_${OS}_${ARCH}.tar.gz"
URL="${RELEASES}/${VERSION}/${TARBALL}"
CHECKSUMS_URL="${RELEASES}/${VERSION}/checksums.txt"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

log "downloading $URL"
curl -fsSL -o "${TMP}/${TARBALL}" "$URL" \
  || err "failed to download $URL"

log "verifying sha256"
curl -fsSL -o "${TMP}/checksums.txt" "$CHECKSUMS_URL" \
  || err "failed to download checksums.txt"

EXPECTED="$(awk -v f="$TARBALL" '$2==f || $2=="*"f {print $1}' "${TMP}/checksums.txt")"
[ -n "$EXPECTED" ] || err "no checksum entry for $TARBALL in checksums.txt"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "${TMP}/${TARBALL}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "${TMP}/${TARBALL}" | awk '{print $1}')"
else
  err "no sha256sum or shasum available on this host"
fi
[ "$EXPECTED" = "$ACTUAL" ] || err "checksum mismatch for $TARBALL (expected $EXPECTED, got $ACTUAL)"

log "unpacking"
tar -xzf "${TMP}/${TARBALL}" -C "$TMP"
# Archive layout: traceway-otel-agent_<ver>_<os>_<arch>/{traceway-otel-agent, default.yaml, ...}
SRC_DIR="${TMP}/traceway-otel-agent_${VERSION}_${OS}_${ARCH}"
[ -f "${SRC_DIR}/traceway-otel-agent" ] \
  || err "binary not found at ${SRC_DIR}/traceway-otel-agent"
[ -f "${SRC_DIR}/default.yaml" ] \
  || err "default.yaml not found at ${SRC_DIR}/default.yaml (malformed release tarball)"

log "installing binary → $BIN_PATH"
$SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "${SRC_DIR}/traceway-otel-agent" "$BIN_PATH"

$SUDO mkdir -p "$CONFIG_DIR"

log "installing config → $CONFIG_PATH"
# The collector config is config/default.yaml, shipped verbatim in the release
# tarball. Keeping it as the single source of truth avoids the heredoc-drift
# bugs we used to have (missing *.utilization opt-ins, platform-specific
# resourcedetection lists).
$SUDO install -m 0644 "${SRC_DIR}/default.yaml" "$CONFIG_PATH"

# Optional logs pipeline: merged in at collector startup via a second
# --config= flag. The overlay contains only the filelog receiver (with the
# user-supplied globs) and a logs pipeline; everything else comes from
# config.yaml.
OVERLAY_PATH="${CONFIG_DIR}/logs-overlay.yaml"
OVERLAY_EXEC_ARG=""
OVERLAY_PLIST_ARG=""
if [ -n "$LOG_PATHS" ]; then
  YAML_INCLUDES=""
  OLD_IFS="$IFS"
  IFS=','
  for p in $LOG_PATHS; do
    # trim surrounding whitespace
    p_trim="$(printf '%s' "$p" | awk '{$1=$1;print}')"
    [ -z "$p_trim" ] && continue
    YAML_INCLUDES="${YAML_INCLUDES}      - \"${p_trim}\"
"
  done
  IFS="$OLD_IFS"

  log "writing logs overlay → $OVERLAY_PATH"
  $SUDO tee "$OVERLAY_PATH" >/dev/null <<EOF
# Traceway OTel Agent — logs overlay, generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Merged on top of config.yaml at startup via a second --config= flag.

receivers:
  filelog:
    include:
${YAML_INCLUDES}    start_at: end
    include_file_path: true
    include_file_name: true

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [memory_limiter, resourcedetection, resource, batch]
      exporters: [otlphttp]
EOF
  OVERLAY_EXEC_ARG=" --config=${OVERLAY_PATH}"
  OVERLAY_PLIST_ARG="
    <string>--config=${OVERLAY_PATH}</string>"
else
  # Clean up any stale overlay from a previous install-with-logs.
  $SUDO rm -f "$OVERLAY_PATH"
fi

# Optional process-metrics pipeline: same overlay pattern as logs. The
# hostmetrics `process` scraper emits one point per OS process per scrape,
# so it's gated behind TRACEWAY_PROCESS_NAMES — empty means scraper stays
# off (the default in config.yaml), `*` means all processes (no filter),
# anything else is an exact-match include list.
PROCESS_OVERLAY_PATH="${CONFIG_DIR}/process-overlay.yaml"
PROCESS_OVERLAY_EXEC_ARG=""
PROCESS_OVERLAY_PLIST_ARG=""
if [ -n "$PROCESS_NAMES" ]; then
  if [ "$PROCESS_NAMES" = "*" ]; then
    INCLUDE_BLOCK=""
  else
    NAMES_YAML=""
    OLD_IFS="$IFS"
    IFS=','
    for n in $PROCESS_NAMES; do
      n_trim="$(printf '%s' "$n" | awk '{$1=$1;print}')"
      [ -z "$n_trim" ] && continue
      NAMES_YAML="${NAMES_YAML}          - \"${n_trim}\"
"
    done
    IFS="$OLD_IFS"
    INCLUDE_BLOCK="        include:
          match_type: strict
          names:
${NAMES_YAML}"
  fi

  log "writing process overlay → $PROCESS_OVERLAY_PATH"
  $SUDO tee "$PROCESS_OVERLAY_PATH" >/dev/null <<EOF
# Traceway OTel Agent — process-metrics overlay, generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Merged on top of config.yaml at startup via a second --config= flag.

receivers:
  hostmetrics:
    scrapers:
      process:
        mute_process_exe_error: true
        mute_process_user_error: true
        mute_process_io_error: true
${INCLUDE_BLOCK}
EOF
  PROCESS_OVERLAY_EXEC_ARG=" --config=${PROCESS_OVERLAY_PATH}"
  PROCESS_OVERLAY_PLIST_ARG="
    <string>--config=${PROCESS_OVERLAY_PATH}</string>"
else
  # Clean up any stale overlay from a previous install-with-process-metrics.
  $SUDO rm -f "$PROCESS_OVERLAY_PATH"
fi

log "writing token → $TOKEN_PATH (mode 0600)"
$SUDO tee "$TOKEN_PATH" >/dev/null <<EOF
TRACEWAY_TOKEN=${TRACEWAY_TOKEN}
TRACEWAY_ENDPOINT=${ENDPOINT}
TRACEWAY_SERVICE_NAME=${SERVICE_NAME}
EOF
$SUDO chmod 600 "$TOKEN_PATH"

if [ "$OS" = "linux" ]; then
  log "installing systemd unit → $UNIT_PATH"
  $SUDO tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=Traceway OTel Agent
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${TOKEN_PATH}
ExecStart=${BIN_PATH} --config=${CONFIG_PATH}${OVERLAY_EXEC_ARG}${PROCESS_OVERLAY_EXEC_ARG}
Restart=on-failure
RestartSec=10s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now traceway-otel-agent.service
else
  log "installing launchd plist → $PLIST_PATH"
  # macOS launchd has no EnvironmentFile equivalent, so env vars are inline.
  $SUDO tee "$PLIST_PATH" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tracewayapp.otel-agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN_PATH}</string>
    <string>--config=${CONFIG_PATH}</string>${OVERLAY_PLIST_ARG}${PROCESS_OVERLAY_PLIST_ARG}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TRACEWAY_TOKEN</key><string>${TRACEWAY_TOKEN}</string>
    <key>TRACEWAY_ENDPOINT</key><string>${ENDPOINT}</string>
    <key>TRACEWAY_SERVICE_NAME</key><string>${SERVICE_NAME}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/traceway-otel-agent.log</string>
  <key>StandardErrorPath</key><string>/var/log/traceway-otel-agent.log</string>
</dict>
</plist>
EOF
  $SUDO chown root:wheel "$PLIST_PATH"
  # 600 (root-only): the plist embeds TRACEWAY_TOKEN under EnvironmentVariables,
  # so it must not be world-readable. launchd loads /Library/LaunchDaemons/
  # plists owned by root at either 600 or 644, so 600 is fine.
  $SUDO chmod 600 "$PLIST_PATH"
  $SUDO launchctl unload "$PLIST_PATH" 2>/dev/null || true
  $SUDO launchctl load -w "$PLIST_PATH"
fi

log "waiting for health check on 127.0.0.1:13133"
i=0
until curl -fsS http://127.0.0.1:13133/ >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -gt 15 ]; then
    if [ "$OS" = "linux" ]; then
      err "agent failed to come up. Logs: journalctl -u traceway-otel-agent -n 50"
    else
      err "agent failed to come up. Logs: tail -n 50 /var/log/traceway-otel-agent.log"
    fi
  fi
  sleep 1
done

log "traceway-otel-agent ${VERSION} is running → shipping to ${ENDPOINT}"
if [ -z "$LOG_PATHS" ]; then
  log "note: logs pipeline is disabled (set TRACEWAY_LOG_PATHS and re-run to enable)"
fi
if [ -z "$PROCESS_NAMES" ]; then
  log "note: per-process metrics are disabled (set TRACEWAY_PROCESS_NAMES=<name1,name2> or '*' and re-run to enable)"
fi
