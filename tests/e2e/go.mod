module github.com/tracewayapp/traceway-otel-agent/tests/e2e

go 1.25.0

require github.com/tracewayapp/traceway-otel-agent/tests/mockotlp v0.0.0

require (
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.30.0 // indirect
	go.opentelemetry.io/proto/otlp v1.11.0 // indirect
	golang.org/x/net v0.58.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.41.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260818201246-1b0934165a6f // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260818201246-1b0934165a6f // indirect
	google.golang.org/grpc v1.83.1 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
)

replace github.com/tracewayapp/traceway-otel-agent/tests/mockotlp => ../mockotlp
