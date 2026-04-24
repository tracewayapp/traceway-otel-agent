#!/usr/bin/env bash
# Traceway OTel Agent uninstaller (Linux / macOS).
#
#   curl -fsSL https://install.tracewayapp.com/uninstall.sh | bash

set -eu

err() { printf 'traceway-uninstall: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'traceway-uninstall: %s\n' "$*"; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || err "root required; install sudo or run as root"
  SUDO="sudo"
fi

case "$(uname -s)" in
  Linux)
    log "stopping + disabling systemd service"
    $SUDO systemctl disable --now traceway-otel-agent.service 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/traceway-otel-agent.service
    $SUDO systemctl daemon-reload 2>/dev/null || true
    $SUDO rm -rf /etc/traceway-otel-agent
    $SUDO rm -f /usr/local/bin/traceway-otel-agent
    ;;
  Darwin)
    log "unloading launchd plist"
    $SUDO launchctl unload -w /Library/LaunchDaemons/com.tracewayapp.otel-agent.plist 2>/dev/null || true
    $SUDO rm -f /Library/LaunchDaemons/com.tracewayapp.otel-agent.plist
    $SUDO rm -rf /usr/local/etc/traceway-otel-agent
    $SUDO rm -f /usr/local/bin/traceway-otel-agent
    $SUDO rm -f /var/log/traceway-otel-agent.log
    ;;
  *)
    err "unsupported OS: $(uname -s)"
    ;;
esac

log "traceway-otel-agent removed"
