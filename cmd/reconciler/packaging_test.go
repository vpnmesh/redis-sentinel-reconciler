package main

import (
	"os"
	"os/exec"
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
		t.Fatal("optional EnvironmentFile=- hides parse errors; shipped unit must use --config")
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
	if !strings.Contains(s, "SENTINEL_ADDR=") {
		t.Fatal("missing SENTINEL_ADDR")
	}
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(line, "SENTINEL_ADDR=") && strings.TrimSpace(strings.TrimPrefix(line, "SENTINEL_ADDR=")) != "" {
			t.Fatalf("shipped SENTINEL_ADDR must be empty, got %q", line)
		}
		if strings.HasPrefix(line, "REDIS_ADDRS=") && strings.TrimSpace(strings.TrimPrefix(line, "REDIS_ADDRS=")) != "" {
			t.Fatalf("shipped REDIS_ADDRS must be empty, got %q", line)
		}
	}
	for _, want := range []string{
		"can become master",
		"whole cluster",
		"this host",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("default file should explain %q", want)
		}
	}
}

func TestInstallSystemdScriptStages(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("caller")
	}
	root := filepath.Join(filepath.Dir(file), "../..")
	script := filepath.Join(root, "scripts/install-systemd.sh")
	dir := t.TempDir()
	bin := filepath.Join(dir, "reconciler")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(dir, "stage")
	c := exec.Command("bash", script)
	c.Dir = dir
	c.Env = append(os.Environ(),
		"DESTDIR="+dest,
		"BIN="+bin,
		"PREFIX=/usr",
	)
	out, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("install-systemd: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(dest, "usr/bin/reconciler")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dest, "lib/systemd/system/redis-sentinel-reconciler.service")); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(dest, "etc/default/redis-sentinel-reconciler")
	if _, err := os.Stat(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestShippedPostinstExplainsRequired(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("caller")
	}
	path := filepath.Join(filepath.Dir(file), "../../packaging/deb/postinst")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, want := range []string{
		"/etc/default/redis-sentinel-reconciler",
		"SENTINEL_ADDR",
		"REDIS_ADDRS",
		"this host's Sentinel",
		"can become master",
		"systemctl enable --now redis-sentinel-reconciler",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("postinst missing %q", want)
		}
	}
}

func TestHelmChartStatefulSetAndDaemonSet(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("caller")
	}
	root := filepath.Join(filepath.Dir(file), "../..")
	ds, err := os.ReadFile(filepath.Join(root, "deploy/helm/redis-sentinel-reconciler/templates/daemonset.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	sts, err := os.ReadFile(filepath.Join(root, "deploy/helm/redis-sentinel-reconciler/templates/statefulset.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(ds), "kind: DaemonSet") || !strings.Contains(string(ds), `eq .Values.workload "DaemonSet"`) {
		t.Fatal("DaemonSet template must stay gated on workload=DaemonSet")
	}
	if !strings.Contains(string(sts), "kind: StatefulSet") || !strings.Contains(string(sts), "sentinelFromOrdinal") {
		t.Fatal("StatefulSet template must pair Sentinel via ordinal")
	}
	shippedVals, err := os.ReadFile(filepath.Join(root, "deploy/helm/redis-sentinel-reconciler/values.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(shippedVals), "apply: false") {
		t.Fatal("shipped Helm chart must stay apply: false until Owner flips it")
	}
	kindVals, err := os.ReadFile(filepath.Join(root, "lab/kind/values-rsr.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(kindVals), "workload: StatefulSet") || !strings.Contains(string(kindVals), "pullPolicy: Never") {
		t.Fatal("Kind values must be local StatefulSet (Never pull)")
	}
	if !strings.Contains(string(kindVals), "apply: true") {
		t.Fatal("Kind lab must run --apply on every sidecar")
	}
	composeYml, err := os.ReadFile(filepath.Join(root, "lab/docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(composeYml), "- --apply"); n < 5 {
		t.Fatalf("compose lab must pass --apply on every reconciler sidecar, got %d", n)
	}
	e2e, err := os.ReadFile(filepath.Join(root, "lab/kind/e2e.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(e2e), "want dry-run") || strings.Contains(string(e2e), "restore dry-run") {
		t.Fatal("Kind e2e must test --apply, not restore dry-run as the product under test")
	}
	if !strings.Contains(string(e2e), "--apply") {
		t.Fatal("Kind e2e must require --apply on rsr pods")
	}
	redisVals, err := os.ReadFile(filepath.Join(root, "lab/kind/values-redis.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(redisVals), "replicaCount: 3") || !strings.Contains(string(redisVals), "bitnamilegacy/redis") {
		t.Fatal("Kind Redis values must be 3 replicas on bitnamilegacy images")
	}
	runsh, err := os.ReadFile(filepath.Join(root, "lab/kind/run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(runsh), "25.5.3") || strings.Contains(string(runsh), "17.10.1") {
		t.Fatal("Kind run.sh must pin Bitnami Redis 25.5.3 from the public index")
	}
	chaos, err := os.ReadFile(filepath.Join(root, "lab/kind/chaos.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(chaos), "dual_master") || !strings.Contains(string(chaos), "REPLICAOF NO ONE") {
		t.Fatal("Kind chaos must inject dual writable and require dual_master refuse")
	}
	stress, err := os.ReadFile(filepath.Join(root, "lab/kind/stress.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(stress), "STRESS_ROUNDS") || !strings.Contains(string(stress), "heal_lease_held") {
		t.Fatal("Kind stress must flap MONITOR and assert heal-lease contention")
	}
	h7, err := os.ReadFile(filepath.Join(root, "lab/e2e/hazards/H07_auth_pass.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(h7), "requirepass") || !strings.Contains(string(h7), "re-bound sentinel auth-pass") {
		t.Fatal("H7 must live-test requirepass + auth-pass rebind, not SKIP")
	}
	tlsRun, err := os.ReadFile(filepath.Join(root, "lab/tls/run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(tlsRun), "--tls") || !strings.Contains(string(tlsRun), "--apply") {
		t.Fatal("TLS lab must run reconciler --tls --apply")
	}
	soak, err := os.ReadFile(filepath.Join(root, "lab/e2e/soak/run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(soak), "SOAK_MINUTES") || !strings.Contains(string(soak), "reconciler_once true") {
		t.Fatal("soak must flap MONITOR under --apply")
	}
	if !strings.Contains(string(soak), "wall-clock") {
		t.Fatal("default soak must run to SOAK_MINUTES wall, not finish in seconds")
	}
	t08, err := os.ReadFile(filepath.Join(root, "lab/e2e/08_kill_two_nodes.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(t08), "stop_compose_node") || !strings.Contains(string(t08), "restore old master") {
		t.Fatal("T08 must kill two full nodes and restore the old master first")
	}
	t09, err := os.ReadFile(filepath.Join(root, "lab/e2e/09_failover_sentinel_down.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(t09), "unrelated") || !strings.Contains(string(t09), "compose stop \"redis-$mi\"") {
		t.Fatal("T09 must elect after an unrelated Sentinel is already down")
	}
	runAll, err := os.ReadFile(filepath.Join(root, "lab/e2e/run_all.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(runAll), "08_kill_two_nodes.sh") || !strings.Contains(string(runAll), "09_failover_sentinel_down.sh") {
		t.Fatal("smoke suite must include T08 and T09")
	}
}
