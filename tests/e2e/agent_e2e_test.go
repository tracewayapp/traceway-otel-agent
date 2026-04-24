package e2e

import (
	"bytes"
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/tracewayapp/traceway-otel-agent/tests/mockotlp"
)

// Paths are relative to this test file.
const (
	binaryPath  = "../../dist/traceway-otel-agent"
	baseConfig  = "../../config/default.yaml"
	fastOverlay = "testdata/fast-overlay.yaml"
)

func TestAgent_ExportsHostMetrics(t *testing.T) {
	bin, err := filepath.Abs(binaryPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(bin); err != nil {
		t.Skipf("collector binary not found at %s — run `make build` first", bin)
	}

	mock := mockotlp.New()
	defer mock.Close()

	// Exercise the real production config; the overlay only shrinks timings
	// so the test completes in seconds.
	base, err := filepath.Abs(baseConfig)
	if err != nil {
		t.Fatal(err)
	}
	overlay, err := filepath.Abs(fastOverlay)
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, "--config="+base, "--config="+overlay)
	cmd.Env = append(os.Environ(),
		"TRACEWAY_TOKEN=test-token-e2e",
		"TRACEWAY_ENDPOINT="+mock.URL(),
		"TRACEWAY_SERVICE_NAME=ci-e2e",
	)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stdout

	if err := cmd.Start(); err != nil {
		t.Fatalf("starting collector: %v", err)
	}
	t.Cleanup(func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	})

	if !waitForHealth(t, 15*time.Second) {
		t.Fatalf("health check did not come up\n--- collector stdout/stderr ---\n%s", stdout.String())
	}

	// Wait for ≥ 2 batches. `system.cpu.utilization` is a gauge computed
	// from the delta of two `system.cpu.time` samples, so the first batch
	// ever exported won't contain it. Waiting for two batches guarantees
	// the second scrape has happened.
	if !waitFor(t, 20*time.Second, func() bool { return mock.Count() >= 2 }) {
		t.Fatalf("fewer than 2 OTLP requests received in time (got %d)\n--- collector stdout/stderr ---\n%s",
			mock.Count(), stdout.String())
	}

	// Header assertions on the first received metrics request.
	headers := mock.MetricsHeaders()
	if len(headers) == 0 {
		t.Fatal("expected headers to be recorded alongside received metrics requests")
	}
	h := headers[0]
	if got, want := h.Get("Authorization"), "Bearer test-token-e2e"; got != want {
		t.Errorf("Authorization = %q, want %q", got, want)
	}
	if got, want := h.Get("Content-Type"), "application/x-protobuf"; got != want {
		t.Errorf("Content-Type = %q, want %q", got, want)
	}
	if got, want := h.Get("Content-Encoding"), "gzip"; got != want {
		t.Errorf("Content-Encoding = %q, want %q", got, want)
	}

	// Resource + metric-name assertions.
	sawServiceName := false
	expected := map[string]bool{
		"system.cpu.utilization": false,
		"system.memory.usage":    false,
		"system.network.io":      false,
	}
	for _, req := range mock.Metrics() {
		for _, rm := range req.GetResourceMetrics() {
			for _, kv := range rm.GetResource().GetAttributes() {
				if kv.GetKey() == "service.name" && kv.GetValue().GetStringValue() == "ci-e2e" {
					sawServiceName = true
				}
			}
			for _, sm := range rm.GetScopeMetrics() {
				for _, m := range sm.GetMetrics() {
					if _, ok := expected[m.GetName()]; ok {
						expected[m.GetName()] = true
					}
				}
			}
		}
	}
	if !sawServiceName {
		t.Errorf("expected service.name=ci-e2e in resource attrs; was not present")
	}
	for name, saw := range expected {
		if !saw {
			t.Errorf("expected metric %q in received data; was not present", name)
		}
	}

	t.Logf("received %d OTLP requests; pipeline is healthy on %s/%s",
		mock.Count(), runtime.GOOS, runtime.GOARCH)
}

func waitForHealth(t *testing.T, timeout time.Duration) bool {
	t.Helper()
	client := &http.Client{Timeout: 2 * time.Second}
	return waitFor(t, timeout, func() bool {
		resp, err := client.Get("http://127.0.0.1:13133/")
		if err != nil {
			return false
		}
		_ = resp.Body.Close()
		return resp.StatusCode == http.StatusOK
	})
}

func waitFor(t *testing.T, timeout time.Duration, cond func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}
