SHELL := /bin/bash

GOFMT = $(shell go env GOROOT)/bin/gofmt

.PHONY: daemon test fmt-check vet image

daemon:
	CGO_ENABLED=0 GOOS=linux go build -o bin/sandbox-daemon ./cmd/daemon

test:
	go test -race ./...

fmt-check:
	@test -z "$$($(GOFMT) -l .)" || { $(GOFMT) -l .; exit 1; }

vet:
	go vet ./...

image:
	docker buildx build --platform linux/amd64 -f Dockerfile.substrate-sandbox -t n8n-substrate:latest .
