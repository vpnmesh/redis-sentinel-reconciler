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

func TestParseConfig_RequiresSentinelAndRedis(t *testing.T) {
	_, err := parseConfig(nil, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("expected missing required settings")
	}
	msg := err.Error()
	for _, want := range []string{
		"missing required settings",
		"SENTINEL_ADDR",
		"REDIS_ADDRS",
		"--sentinel-addr",
		"--redis-addrs",
		"this host",
		"can become master",
		"whole cluster",
		"Example: SENTINEL_ADDR=",
		"Example: REDIS_ADDRS=",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("missing %q in:\n%s", want, msg)
		}
	}
}

func TestParseConfig_RequiresRedisSeeds(t *testing.T) {
	_, err := parseConfig([]string{"--sentinel-addr=127.0.0.1:26379"}, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("expected redis-addrs required")
	}
	msg := err.Error()
	if !strings.Contains(msg, "REDIS_ADDRS") || !strings.Contains(msg, "can become master") {
		t.Fatalf("expected redis required help, got %v", err)
	}
	if strings.Contains(msg, "SENTINEL_ADDR  (--sentinel-addr") {
		t.Fatalf("sentinel was set; should not ask for SENTINEL_ADDR:\n%s", msg)
	}
}

func TestParseConfig_RequiresSentinelOnly(t *testing.T) {
	_, err := parseConfig([]string{"--redis-addrs=10.0.0.1:6379,10.0.0.2:6379"}, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("expected sentinel required")
	}
	msg := err.Error()
	if !strings.Contains(msg, "SENTINEL_ADDR") || !strings.Contains(msg, "this host") {
		t.Fatalf("expected sentinel required help, got %v", err)
	}
	if strings.Contains(msg, "REDIS_ADDRS  (--redis-addrs") {
		t.Fatalf("redis was set; should not ask for REDIS_ADDRS:\n%s", msg)
	}
}

func TestParseConfig_MissingRequiredMentionsConfigPath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rsr.env")
	if err := os.WriteFile(path, []byte("APPLY=false\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := parseConfig([]string{"--config", path}, getenvMap(nil), io.Discard)
	if err == nil || !strings.Contains(err.Error(), path) {
		t.Fatalf("expected config path in error, got %v", err)
	}
}

func TestParseConfig_EnvSentinelAndApplyGuard(t *testing.T) {
	cfg, err := parseConfig(nil, getenvMap(map[string]string{
		"RSR_SENTINEL_ADDR": "127.0.0.1:26379",
		"RSR_REDIS_ADDRS":   "10.0.0.1:6379",
		"RSR_APPLY":         "true",
	}), io.Discard)
	if err != nil {
		t.Fatalf("sidecar default --local-sentinel=true should allow APPLY: %v", err)
	}
	if !cfg.Apply || !cfg.LocalSentinel {
		t.Fatalf("expected apply+local, got apply=%v local=%v", cfg.Apply, cfg.LocalSentinel)
	}

	_, err = parseConfig([]string{"--local-sentinel=false"}, getenvMap(map[string]string{
		"SENTINEL_ADDR": "127.0.0.1:26379",
		"REDIS_ADDRS":   "10.0.0.1:6379",
		"APPLY":         "true",
	}), io.Discard)
	if err == nil || !strings.Contains(err.Error(), "local-sentinel") {
		t.Fatalf("expected apply-without-local error, got %v", err)
	}

	cfg, err = parseConfig(nil, getenvMap(map[string]string{
		"SENTINEL_ADDR": "127.0.0.1:26379",
		"RSR_APPLY":     "true",
		"REDIS_ADDRS":   "10.0.0.1:6379,10.0.0.2:6379",
		"INTERVAL":      "45s",
	}), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Apply || !cfg.LocalSentinel || cfg.Interval != 45*time.Second {
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
	for _, want := range []string{
		"-tls", "-redis-username", "-sentinel-username", "-sentinel-redis-username", "-config",
		"SENTINEL_ADDR", "REDIS_ADDRS", "same knobs",
		"this host's Sentinel", "can become master",
	} {
		if !strings.Contains(help, want) {
			t.Errorf("help missing %s\n%s", want, help)
		}
	}
}

func TestParseConfig_FlagEnvFileSameKnob(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rsr.env")
	body := `
sentinel-addr=from-file:26379
REDIS_ADDRS=10.0.0.1:6379
tls=true
tls-skip-verify=true
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := parseConfig([]string{"--config", path}, getenvMap(nil), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SentinelAddrs[0] != "from-file:26379" || cfg.TLS == nil || !cfg.TLS.InsecureSkipVerify {
		t.Fatalf("file hyphen keys: %#v tls=%v", cfg.SentinelAddrs, cfg.TLS)
	}

	cfg, err = parseConfig(nil, getenvMap(map[string]string{
		"TLS":             "true",
		"TLS_SKIP_VERIFY": "true",
		"SENTINEL_ADDR":   "from-env:26379",
		"REDIS_ADDRS":     "10.0.0.1:6379",
	}), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SentinelAddrs[0] != "from-env:26379" || cfg.TLS == nil {
		t.Fatalf("unprefixed env TLS: addrs=%v tls=%v", cfg.SentinelAddrs, cfg.TLS)
	}
}

func TestParseConfig_DefaultIntervalAndLocal(t *testing.T) {
	cfg, err := parseConfig([]string{"--sentinel-addr=a:26379", "--redis-addrs=a:6379"}, getenvMap(nil), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Interval != 30*time.Second || !cfg.LocalSentinel {
		t.Fatalf("interval=%s local=%v", cfg.Interval, cfg.LocalSentinel)
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
