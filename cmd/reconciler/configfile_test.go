package main

import (
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestParseEnvLine_SecretChars(t *testing.T) {
	key, val, err := parseEnvLine(`REDIS_PASSWORD="p$a#ss word"`)
	if err != nil {
		t.Fatal(err)
	}
	if key != "REDIS_PASSWORD" || val != `p$a#ss word` {
		t.Fatalf("got %s=%q", key, val)
	}

	_, val, err = parseEnvLine(`REDIS_PASSWORD=p$a#ss`)
	if err != nil {
		t.Fatal(err)
	}
	if val != `p$a#ss` {
		t.Fatalf("unquoted $ # must stay literal, got %q", val)
	}

	_, val, err = parseEnvLine(`TOKEN='it'"'"'s fine'`)
	if err == nil {
		t.Fatalf("shell concatenation is not supported, got %q", val)
	}

	_, val, err = parseEnvLine(`TOKEN='p$a#ss word'`)
	if err != nil {
		t.Fatal(err)
	}
	if val != `p$a#ss word` {
		t.Fatalf("single-quoted got %q", val)
	}
}

func TestLoadEnvFile_AndParseConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rsr.env")
	body := `# vault-style secret: $ # space quotes
SENTINEL_ADDR=db-n1.example.com:26379
REDIS_ADDRS=db-n1.example.com:6379,db-n2.example.com:6379
REDIS_PASSWORD="p$a#ss word"
APPLY=false
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := parseConfig([]string{"--config", path, "--local-sentinel"}, getenvMap(nil), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SentinelAddrs[0] != "db-n1.example.com:26379" {
		t.Fatalf("sentinel: %v", cfg.SentinelAddrs)
	}
	if cfg.RedisPassword != `p$a#ss word` {
		t.Fatalf("password %q", cfg.RedisPassword)
	}
	if len(cfg.RedisAddrs) != 2 {
		t.Fatalf("redis addrs: %v", cfg.RedisAddrs)
	}
}

func TestLoadEnvFile_ProcessEnvOverridesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rsr.env")
	if err := os.WriteFile(path, []byte("SENTINEL_ADDR=from-file:26379\nREDIS_ADDRS=10.0.0.1:6379\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := parseConfig([]string{"--config", path}, getenvMap(map[string]string{
		"SENTINEL_ADDR": "from-env:26379",
	}), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SentinelAddrs[0] != "from-env:26379" {
		t.Fatalf("env should win: %v", cfg.SentinelAddrs)
	}
}

func TestLoadEnvFile_MissingIsError(t *testing.T) {
	_, err := parseConfig([]string{"--config", filepath.Join(t.TempDir(), "nope")}, getenvMap(nil), io.Discard)
	if err == nil {
		t.Fatal("expected missing --config error")
	}
}

func TestPeekConfigPath(t *testing.T) {
	p, err := peekConfigPath([]string{"--once", "--config", "/etc/default/rsr"})
	if err != nil || p != "/etc/default/rsr" {
		t.Fatalf("got %q err=%v", p, err)
	}
	p, err = peekConfigPath([]string{"--config=/x"})
	if err != nil || p != "/x" {
		t.Fatalf("got %q err=%v", p, err)
	}
	if _, err := peekConfigPath([]string{"--config"}); err == nil {
		t.Fatal("expected error")
	}
}
