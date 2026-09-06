# syntax=docker/dockerfile:1

FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/reconciler ./cmd/reconciler

FROM alpine:3.20 AS certs
RUN apk add --no-cache ca-certificates

# Static binary + CA bundle. UID 65534 (nobody); no shell.
FROM scratch
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=certs /etc/passwd /etc/passwd
COPY --from=certs /etc/group /etc/group
COPY --from=build /out/reconciler /usr/local/bin/reconciler
USER 65534:65534
LABEL org.opencontainers.image.source="https://github.com/vpnmesh/redis-sentinel-reconciler" \
      org.opencontainers.image.url="https://hub.docker.com/r/vpnmesh/redis-sentinel-reconciler" \
      org.opencontainers.image.title="redis-sentinel-reconciler" \
      org.opencontainers.image.description="Sidecar that heals stale Redis/Valkey Sentinel master advertisements." \
      org.opencontainers.image.licenses="Apache-2.0"
ENTRYPOINT ["/usr/local/bin/reconciler"]
