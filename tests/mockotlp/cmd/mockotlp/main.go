// mockotlp runs the OTLP/HTTP receiver as a standalone process. Used by
// tests/install/run.sh inside the install-smoke-test container.
//
//	go run . -addr :4318
package main

import (
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/tracewayapp/traceway-otel-agent/tests/mockotlp"
)

func main() {
	addr := flag.String("addr", ":4318", "listen address (host:port)")
	flag.Parse()

	r := &mockotlp.Receiver{}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("mockotlp: listen %s: %v", *addr, err)
	}
	srv := &http.Server{Handler: mockotlp.Handler(r)}
	log.Printf("mockotlp: listening on %s", ln.Addr().String())

	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("mockotlp: serve: %v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Printf("mockotlp: shutting down — received %d OTLP requests", r.Count())
	_ = srv.Close()
}
