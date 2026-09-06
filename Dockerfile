# syntax=docker/dockerfile:1

FROM golang:1.23-alpine AS build
ARG VERSION=dev
ARG REVISION=unknown
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${REVISION}" \
      -o /out/reconciler ./cmd/reconciler

FROM alpine:3.20 AS certs
RUN apk add --no-cache ca-certificates

# Static binary + CA bundle. UID 65534 (nobody); no shell.
FROM scratch
ARG VERSION=dev
ARG REVISION=unknown
ARG VCS_TAG=
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=certs /etc/passwd /etc/passwd
COPY --from=certs /etc/group /etc/group
COPY --from=build /out/reconciler /usr/local/bin/reconciler
USER 65534:65534
LABEL org.opencontainers.image.source="https://github.com/vpnmesh/redis-sentinel-reconciler" \
      org.opencontainers.image.url="https://hub.docker.com/r/vpnmesh/redis-sentinel-reconciler" \
      org.opencontainers.image.title="redis-sentinel-reconciler" \
      org.opencontainers.image.description="Sidecar that heals stale Redis/Valkey Sentinel master advertisements." \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.version="${VERSION}" \
      git.commit="${REVISION}" \
      git.tag="${VCS_TAG}"
ENTRYPOINT ["/usr/local/bin/reconciler"]
