package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestShippedUnitUsesConfigNotOptionalEnvFile(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("caller")
	}
	unit := filepath.Join(filepath.Dir(file), "../../deploy/systemd/redis-sentinel-reconciler.service")
	b, err := os.ReadFile(unit)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if strings.Contains(s, "EnvironmentFile=-") {
		t.Fatal("optional EnvironmentFile=- hides parse errors; shipped unit must fail closed")
	}
	if strings.Contains(s, "EnvironmentFile=") {
		t.Fatal("shipped unit must not let systemd parse secrets; use --config")
	}
	if !strings.Contains(s, "/usr/bin/reconciler") {
		t.Fatal("binary path must be /usr/bin/reconciler")
	}
	if !strings.Contains(s, "--config /etc/default/redis-sentinel-reconciler") {
		t.Fatal("ExecStart must pass --config (SENTINEL_ADDR is not implied by --local-sentinel)")
	}
	if !strings.Contains(s, "--local-sentinel") {
		t.Fatal("missing --local-sentinel")
	}
}

func TestShippedDefaultIsNotLoopbackTLS(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("caller")
	}
	path := filepath.Join(filepath.Dir(file), "../../deploy/systemd/redis-sentinel-reconciler.default")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if strings.Contains(s, "SENTINEL_ADDR=127.0.0.1") {
		t.Fatal("example must not default TLS sidecars to 127.0.0.1")
	}
	if strings.Contains(s, "METRICS_ADDR=127.0.0.1:9090") {
		t.Fatal("sample metrics port 9090 collides with common exporters")
	}
}
