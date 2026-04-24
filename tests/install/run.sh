#!/usr/bin/env bash
# Install smoke test: run scripts/install.sh inside a systemd-enabled Ubuntu
# container, against a locally-hosted fake release + mock OTLP receiver, and
# assert that the service starts and metrics actually flow.
#
# Prereqs:
#   - ./dist/traceway-otel-agent built via `make build`
#   - docker available
#
# Run from the repo root:  bash tests/install/run.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

TAG="v0.0.0-smoke-test"
OS="linux"
ARCH="amd64"
IMAGE="traceway-otel-install-smoke:latest"
MOCK_PORT=4318

step() { printf "\n=== %s ===\n" "$*"; }

[ -f dist/traceway-otel-agent ] \
  || { echo "build first: make build"; exit 1; }

step "build mockotlp binary for linux/amd64"
STAGE="$(mktemp -d)"
trap 'docker rm -f "${CID:-}" >/dev/null 2>&1 || true; rm -rf "$STAGE"' EXIT

(
  cd tests/mockotlp
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$STAGE/mockotlp" ./cmd/mockotlp
)

step "assemble fake release bundle"
PKG="traceway-otel-agent_${TAG}_${OS}_${ARCH}"
mkdir -p "$STAGE/pkg/$PKG" "$STAGE/fixture/$TAG"
cp dist/traceway-otel-agent "$STAGE/pkg/$PKG/traceway-otel-agent"
cp README.md config/default.yaml "$STAGE/pkg/$PKG/"
cp -r scripts/service "$STAGE/pkg/$PKG/service"
tar -C "$STAGE/pkg" -czf "$STAGE/fixture/$TAG/$PKG.tar.gz" "$PKG"
( cd "$STAGE/fixture/$TAG" && sha256sum "$PKG.tar.gz" > checksums.txt )
echo "fixture ready:"
ls -la "$STAGE/fixture/$TAG/"

step "build systemd docker image"
docker build -t "$IMAGE" -f tests/install/Dockerfile.ubuntu tests/install/ >/dev/null

step "start container"
CID="$(docker run -d --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -v "$STAGE/fixture:/fixture:ro" \
  -v "$STAGE/mockotlp:/usr/local/bin/mockotlp:ro" \
  -v "$REPO_ROOT/scripts:/traceway-scripts:ro" \
  "$IMAGE")"
echo "container: $CID"

step "wait for systemd"
for i in $(seq 30); do
  state="$(docker exec "$CID" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in
    running|degraded) echo "systemd: $state"; break ;;
  esac
  if [ "$i" -eq 30 ]; then
    docker exec "$CID" systemctl --failed || true
    echo "systemd did not become ready"; exit 1
  fi
  sleep 1
done

step "start mock OTLP receiver inside container"
docker exec -d "$CID" /usr/local/bin/mockotlp -addr ":${MOCK_PORT}"
for i in $(seq 20); do
  if docker exec "$CID" curl -fsS "http://127.0.0.1:${MOCK_PORT}/healthz" >/dev/null 2>&1; then
    echo "mock: up"
    break
  fi
  [ "$i" -eq 20 ] && { echo "mock OTLP never came up"; exit 1; }
  sleep 0.5
done

step "run install.sh against fake release"
docker exec \
  -e TRACEWAY_TOKEN=smoke-test-token \
  -e TRACEWAY_ENDPOINT="http://127.0.0.1:${MOCK_PORT}" \
  -e TRACEWAY_RELEASES_URL="file:///fixture" \
  -e TRACEWAY_VERSION="$TAG" \
  -e TRACEWAY_SERVICE_NAME=smoke-test-host \
  "$CID" bash /traceway-scripts/install.sh

step "assert service is active"
docker exec "$CID" systemctl is-active traceway-otel-agent

step "assert health check"
docker exec "$CID" curl -fsS http://127.0.0.1:13133/ >/dev/null

step "assert config file is correct"
docker exec "$CID" test -f /etc/traceway-otel-agent/config.yaml
docker exec "$CID" grep -q 'Bearer ${env:TRACEWAY_TOKEN}' /etc/traceway-otel-agent/config.yaml

step "wait for mock to receive at least one batch"
got=0
for i in $(seq 30); do
  # `|| echo 0` guards against transient curl failures tripping pipefail
  # and exiting the script mid-poll.
  got="$(docker exec "$CID" curl -fsS "http://127.0.0.1:${MOCK_PORT}/count" 2>/dev/null \
          | tr -d '[:space:]' || echo 0)"
  if [ "${got:-0}" -ge 1 ]; then
    break
  fi
  sleep 1
done

if [ "${got:-0}" -lt 1 ]; then
  echo "--- collector journal ---"
  docker exec "$CID" journalctl -u traceway-otel-agent --no-pager || true
  echo "mock received 0 batches after 30s"; exit 1
fi
echo "mock received $got batch(es)"

step "install smoke test PASSED"
