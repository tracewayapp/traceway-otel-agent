# Traceway OTel Agent — developer make targets.
#
#   make build         Build the collector via OCB → dist/traceway-otel-agent
#   make validate      Validate config/default.yaml against the built binary
#   make lint          Bash + shellcheck + yamllint (skip gracefully if missing)
#   make test-e2e      Run the in-process OTLP receiver test (layer 2)
#   make test-install  Run the docker-based install smoke test (layer 3)
#   make test-local    validate + lint + test-e2e (no docker needed)
#   make clean         Remove dist/

BINARY := dist/traceway-otel-agent
OCB    ?= $(shell command -v builder 2>/dev/null)
GO     ?= go

.PHONY: build
build: $(BINARY)

$(BINARY):
	@if [ -z "$(OCB)" ]; then \
		echo "builder (OCB) not on PATH; install with:"; \
		echo "  $(GO) install go.opentelemetry.io/collector/cmd/builder@v0.159.0"; \
		exit 1; \
	fi
	$(OCB) --config=builder-config.yaml

VALIDATE_ENV := TRACEWAY_TOKEN=validate-placeholder \
	TRACEWAY_ENDPOINT=https://cloud.tracewayapp.com/api/otel \
	TRACEWAY_SERVICE_NAME=local-validate \
	TRACEWAY_STORAGE_DIR=/tmp/traceway-validate-storage

# The second validate loads every overlay a fully-featured install runs with:
# the shipped storage overlay plus the shapes install.sh/install.ps1 generate
# when TRACEWAY_LOG_PATHS / TRACEWAY_PROCESS_NAMES are set. These are not
# covered by the other test layers.
.PHONY: validate
validate: build
	$(VALIDATE_ENV) ./$(BINARY) validate --config=config/default.yaml
	$(VALIDATE_ENV) ./$(BINARY) validate --config=config/default.yaml \
		--config=config/storage-overlay.yaml \
		--config=tests/validate/logs-overlay.yaml \
		--config=tests/validate/process-overlay.yaml

.PHONY: lint
lint:
	bash -n scripts/install.sh
	bash -n scripts/uninstall.sh
	bash -n scripts/release.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/install.sh scripts/uninstall.sh scripts/release.sh tests/install/run.sh; \
	else \
		echo "shellcheck not installed, skipping"; \
	fi
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}, comments: {min-spaces-from-content: 1}}}' \
			config/ builder-config.yaml .github/workflows/ tests/e2e/testdata/ tests/validate/; \
	else \
		echo "yamllint not installed, skipping"; \
	fi

.PHONY: test-e2e
test-e2e: build
	cd tests/e2e && $(GO) test -v -timeout 120s ./...

.PHONY: test-install
test-install: build
	bash tests/install/run.sh

.PHONY: test-local
test-local: validate lint test-e2e

.PHONY: clean
clean:
	rm -rf dist/
