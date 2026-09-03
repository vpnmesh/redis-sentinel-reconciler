package main

import (
	"bytes"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWantsVersion(t *testing.T) {
	if !wantsVersion([]string{"--version"}) || !wantsVersion([]string{"-version"}) {
		t.Fatal("expected version flags")
	}
	if wantsVersion([]string{"--once"}) {
		t.Fatal("did not expect version")
	}
}

func TestParseConfig_RequiresSentinel(t *testing.T) {
	_, err := parseConfig(nil, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("expected missing sentinel error")
	}
}

func TestParseConfig_RequiresRedisSeeds(t *testing.T) {
	_, err := parseConfig([]string{"--sentinel-addr=127.0.0.1:26379"}, getenvMap(nil), io.Discard)
	if err == nil || !strings.Contains(err.Error(), "redis-addrs") {
		t.Fatalf("expected redis-addrs required, got %v", err)
	}
}

func TestParseConfig_EnvSentinelAndApplyGuard(t *testing.T) {
	_, err := parseConfig(nil, getenvMap(map[string]string{
		"RSR_SENTINEL_ADDR": "127.0.0.1:26379",
		"RSR_REDIS_ADDRS":   "10.0.0.1:6379",
		"RSR_APPLY":         "true",
	}), io.Discard)
	if err == nil || err.Error() == "" {
		t.Fatalf("expected apply-without-local error, got %v", err)
	}

	cfg, err := parseConfig(nil, getenvMap(map[string]string{
		"SENTINEL_ADDR":      "127.0.0.1:26379",
		"RSR_APPLY":          "true",
		"RSR_LOCAL_SENTINEL": "true",
		"REDIS_ADDRS":        "10.0.0.1:6379,10.0.0.2:6379",
		"INTERVAL":           "30s",
	}), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Apply || !cfg.LocalSentinel || cfg.Interval != 30*time.Second {
		t.Fatalf("unexpected cfg: apply=%v local=%v interval=%s", cfg.Apply, cfg.LocalSentinel, cfg.Interval)
	}
	if len(cfg.RedisAddrs) != 2 {
		t.Fatalf("redis addrs: %v", cfg.RedisAddrs)
	}
}

func TestParseConfig_ApplyFlagCompat(t *testing.T) {
	cfg, err := parseConfig([]string{"--sentinel-addr=127.0.0.1:26379", "--local-sentinel", "--redis-addrs=10.0.0.1:6379"}, getenvMap(map[string]string{
		"APPLY_FLAG": "--apply",
	}), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Apply {
		t.Fatal("APPLY_FLAG=--apply should enable apply")
	}
}

func TestParseConfig_FlagOverridesEnv(t *testing.T) {
	cfg, err := parseConfig([]string{
		"--sentinel-addr=127.0.0.1:26379",
		"--redis-addrs=10.0.0.1:6379",
		"--master-name=prod",
		"--interval=45s",
	}, getenvMap(map[string]string{
		"RSR_MASTER_NAME": "from-env",
		"RSR_INTERVAL":    "30s",
	}), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MasterName != "prod" || cfg.Interval != 45*time.Second {
		t.Fatalf("flag should win: %#v", cfg)
	}
}

func TestParseConfig_TLSRequiresEnable(t *testing.T) {
	_, err := parseConfig([]string{"--sentinel-addr=127.0.0.1:26379", "--redis-addrs=10.0.0.1:6379", "--tls-skip-verify"}, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("expected TLS extras without --tls to fail")
	}
}

func TestParseConfig_TLSSkipVerify(t *testing.T) {
	cfg, err := parseConfig([]string{"--sentinel-addr=127.0.0.1:26379", "--redis-addrs=10.0.0.1:6379", "--tls", "--tls-skip-verify"}, getenvMap(nil), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TLS == nil || !cfg.TLS.InsecureSkipVerify {
		t.Fatal("expected skip-verify TLS config")
	}
}

func TestParseConfig_TLSCAFile(t *testing.T) {
	ca := filepath.Join(t.TempDir(), "ca.pem")
	// Minimal invalid PEM is rejected by BuildTLS; write a real-enough file via skip path:
	// use skip-verify + ca is allowed (CA still loaded).
	_, err := parseConfig([]string{
		"--sentinel-addr=127.0.0.1:26379",
		"--redis-addrs=10.0.0.1:6379",
		"--tls",
		"--tls-ca-file", ca,
	}, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("missing CA file should fail")
	}

	if err := os.WriteFile(ca, []byte("not-pem"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = parseConfig([]string{"--sentinel-addr=a:1", "--redis-addrs=a:6379", "--tls", "--tls-ca-file", ca}, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("garbage PEM should fail")
	}
}

func TestParseConfig_SentinelRedisAuth(t *testing.T) {
	cfg, err := parseConfig([]string{
		"--sentinel-addr=127.0.0.1:26379",
		"--redis-addrs=10.0.0.1:6379",
		"--redis-username=probe",
		"--redis-password=probe-pass",
		"--sentinel-redis-username=sentinel",
		"--sentinel-redis-password=repl-pass",
	}, getenvMap(nil), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.RedisUsername != "probe" || cfg.SentinelRedisUsername != "sentinel" || cfg.SentinelRedisPassword != "repl-pass" {
		t.Fatalf("%#v", cfg)
	}
}

func TestParseConfig_Help(t *testing.T) {
	var buf bytes.Buffer
	_, err := parseConfig([]string{"-h"}, getenvMap(nil), &buf)
	if !errors.Is(err, flag.ErrHelp) {
		t.Fatalf("got %v", err)
	}
	help := buf.String()
	for _, want := range []string{"-tls", "-redis-username", "-sentinel-username", "-sentinel-redis-username", "-config"} {
		if !strings.Contains(help, want) {
			t.Errorf("help missing %s\n%s", want, help)
		}
	}
}

func getenvMap(m map[string]string) getenvFunc {
	return func(k string) string {
		if m == nil {
			return ""
		}
		return m[k]
	}
}
