// Package mockotlp is a minimal OTLP/HTTP receiver used by the agent tests.
//
// Call New() to start an in-process server on a random port, inspect
// Metrics() / Logs() for decoded payloads, and Close() when done.
//
// For a standalone binary, see cmd/mockotlp.
package mockotlp

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"

	colllogspb "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	collmetricspb "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	"google.golang.org/protobuf/proto"
)

// Receiver records everything an OTLP/HTTP client sends at it.
type Receiver struct {
	mu             sync.Mutex
	metrics        []*collmetricspb.ExportMetricsServiceRequest
	metricsHeaders []http.Header
	logs           []*colllogspb.ExportLogsServiceRequest
	logsHeaders    []http.Header
	srv            *httptest.Server
}

// New starts an in-process OTLP/HTTP receiver on a random port and returns it.
func New() *Receiver {
	r := &Receiver{}
	r.srv = httptest.NewServer(Handler(r))
	return r
}

// URL is the base URL clients should point at (no trailing slash).
// Append /v1/metrics or /v1/logs to hit the OTLP endpoints.
func (r *Receiver) URL() string {
	if r.srv == nil {
		return ""
	}
	return r.srv.URL
}

// Close stops the server.
func (r *Receiver) Close() {
	if r.srv != nil {
		r.srv.Close()
	}
}

// Metrics returns a snapshot of all ExportMetricsServiceRequests received.
func (r *Receiver) Metrics() []*collmetricspb.ExportMetricsServiceRequest {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*collmetricspb.ExportMetricsServiceRequest, len(r.metrics))
	copy(out, r.metrics)
	return out
}

// Logs returns a snapshot of all ExportLogsServiceRequests received.
func (r *Receiver) Logs() []*colllogspb.ExportLogsServiceRequest {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*colllogspb.ExportLogsServiceRequest, len(r.logs))
	copy(out, r.logs)
	return out
}

// MetricsHeaders returns a snapshot of request headers recorded alongside
// Metrics(), in the same insertion order.
func (r *Receiver) MetricsHeaders() []http.Header {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]http.Header, len(r.metricsHeaders))
	copy(out, r.metricsHeaders)
	return out
}

// LogsHeaders returns a snapshot of request headers recorded alongside
// Logs(), in the same insertion order.
func (r *Receiver) LogsHeaders() []http.Header {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]http.Header, len(r.logsHeaders))
	copy(out, r.logsHeaders)
	return out
}

// Count returns the total number of OTLP requests received.
func (r *Receiver) Count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.metrics) + len(r.logs)
}

// Handler returns an http.Handler that records traffic into r. It's exported
// so the standalone binary can attach it to an http.Server on a fixed port.
func Handler(r *Receiver) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/metrics", r.handleMetrics)
	mux.HandleFunc("/v1/logs", r.handleLogs)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/count", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, "%d\n", r.Count())
	})
	mux.HandleFunc("/summary", func(w http.ResponseWriter, _ *http.Request) {
		r.mu.Lock()
		defer r.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]int{
			"metrics_requests": len(r.metrics),
			"logs_requests":    len(r.logs),
		})
	})
	return mux
}

func readBody(req *http.Request) ([]byte, error) {
	raw, err := io.ReadAll(req.Body)
	if err != nil {
		return nil, err
	}
	_ = req.Body.Close()
	if req.Header.Get("Content-Encoding") != "gzip" {
		return raw, nil
	}
	gr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("gzip reader: %w", err)
	}
	defer gr.Close()
	return io.ReadAll(gr)
}

func writeProtoEmpty(w http.ResponseWriter, msg proto.Message, reqCT string) {
	if reqCT == "application/json" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("{}"))
		return
	}
	out, _ := proto.Marshal(msg)
	w.Header().Set("Content-Type", "application/x-protobuf")
	_, _ = w.Write(out)
}

func (r *Receiver) handleMetrics(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := readBody(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	msg := &collmetricspb.ExportMetricsServiceRequest{}
	if err := proto.Unmarshal(body, msg); err != nil {
		http.Error(w, "unmarshal: "+err.Error(), http.StatusBadRequest)
		return
	}
	r.mu.Lock()
	r.metrics = append(r.metrics, msg)
	r.metricsHeaders = append(r.metricsHeaders, req.Header.Clone())
	r.mu.Unlock()
	writeProtoEmpty(w, &collmetricspb.ExportMetricsServiceResponse{}, req.Header.Get("Content-Type"))
}

func (r *Receiver) handleLogs(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := readBody(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	msg := &colllogspb.ExportLogsServiceRequest{}
	if err := proto.Unmarshal(body, msg); err != nil {
		http.Error(w, "unmarshal: "+err.Error(), http.StatusBadRequest)
		return
	}
	r.mu.Lock()
	r.logs = append(r.logs, msg)
	r.logsHeaders = append(r.logsHeaders, req.Header.Clone())
	r.mu.Unlock()
	writeProtoEmpty(w, &colllogspb.ExportLogsServiceResponse{}, req.Header.Get("Content-Type"))
}
