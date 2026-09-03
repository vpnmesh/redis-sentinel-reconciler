# syntax=docker/dockerfile:1

FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/reconciler ./cmd/reconciler

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /out/reconciler /usr/local/bin/reconciler
USER nobody
ENTRYPOINT ["/usr/local/bin/reconciler"]
