module github.com/tracewayapp/traceway-otel-agent/tests/e2e

go 1.23

require github.com/tracewayapp/traceway-otel-agent/tests/mockotlp v0.0.0

require (
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.20.0 // indirect
	go.opentelemetry.io/proto/otlp v1.3.1 // indirect
	golang.org/x/net v0.23.0 // indirect
	golang.org/x/sys v0.18.0 // indirect
	golang.org/x/text v0.15.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20240513163218-0867130af1f8 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20240513163218-0867130af1f8 // indirect
	google.golang.org/grpc v1.64.0 // indirect
	google.golang.org/protobuf v1.34.2 // indirect
)

replace github.com/tracewayapp/traceway-otel-agent/tests/mockotlp => ../mockotlp
