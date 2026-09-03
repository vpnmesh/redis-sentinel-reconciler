package reconcile

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
)

const metricPrefix = "redis_sentinel_reconciler_"

// Prometheus rename (v0.1.1): counters gained a _total suffix.
// Old: redis_sentinel_reconciler_diverge
// New: redis_sentinel_reconciler_diverge_total
// Last-tick state is a gauge (diverged, would_heal, writable_masters).
// Dashboards: rate/increase on *_total; gauges for “is it bad right now”.
// Scrape must not increment anything.

type counterDef struct {
	name, help string
}

type gaugeDef struct {
	name, help string
}

var counterDefs = []counterDef{
	{"ticks_total", "Reconcile ticks executed."},
	{"noop_total", "Ticks where local Sentinel ads already matched the writable oracle."},
	{"diverge_total", "Ticks where local Sentinel ads disagreed with the writable oracle."},
	{"would_heal_total", "Dry-run ticks that would have healed Sentinel ads."},
	{"heal_attempt_total", "Apply heal attempts started."},
	{"heal_ok_total", "Apply heals that verified ads and a write on the oracle."},
	{"heal_fail_total", "Apply heals that did not verify."},
	{"heal_lease_acquired_total", "Heal leases acquired on the oracle before apply."},
	{"apply_refused_total", "Apply heals refused by a safety guard."},
	{"alert_no_redis_total", "Ticks with no Redis nodes to probe."},
	{"alert_no_writable_total", "Ticks with zero writable Redis masters on the seed list."},
	{"alert_dual_master_total", "Ticks with two or more writable Redis masters."},
	{"alert_equal_epoch_trap_total", "Ticks that detected equal config-epoch and disagreeing ads."},
	{"alert_equal_epoch_escalate_total", "Ticks that refused MONITOR under equal-epoch when FAILOVER was unsafe for a reason other than a stale live-replica advertisement."},
}

var gaugeDefs = []gaugeDef{
	{"diverged", "1 if the last tick saw Sentinel ads disagree with the writable oracle, else 0."},
	{"would_heal", "1 if the last tick would have healed (dry-run), else 0."},
	{"writable_masters", "Writable Redis masters seen on the last tick (oracle seeds)."},
}

// Metrics is a Prometheus text exposition (HELP/TYPE, counters at 0, last-tick gauges).
type Metrics struct {
	mu        sync.Mutex
	counters  map[string]int64
	diverged  int64
	wouldHeal int64
	writable  int64
	labels    string
}

func newMetrics(masterName string, apply bool) *Metrics {
	counters := make(map[string]int64, len(counterDefs))
	for _, d := range counterDefs {
		counters[d.name] = 0
	}
	applyS := "false"
	if apply {
		applyS = "true"
	}
	if masterName == "" {
		masterName = "mymaster"
	}
	return &Metrics{
		counters: counters,
		labels:   fmt.Sprintf(`{master_name="%s",apply="%s"}`, promLabelValue(masterName), applyS),
	}
}

func promLabelValue(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}

func counterKey(name string) string {
	if strings.HasSuffix(name, "_total") {
		return name
	}
	return name + "_total"
}

func (m *Metrics) Inc(name string) {
	if m == nil {
		return
	}
	key := counterKey(name)
	m.mu.Lock()
	if _, ok := m.counters[key]; ok {
		m.counters[key]++
	}
	m.mu.Unlock()
}

func (m *Metrics) ResetTickGauges() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.diverged = 0
	m.wouldHeal = 0
	m.writable = 0
	m.mu.Unlock()
}

func (m *Metrics) SetWritableMasters(n int) {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.writable = int64(n)
	m.mu.Unlock()
}

func (m *Metrics) NoteDiverged() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.diverged = 1
	m.mu.Unlock()
}

func (m *Metrics) NoteWouldHeal() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.wouldHeal = 1
	m.mu.Unlock()
}

func (m *Metrics) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		m.writePrometheus(w)
	})
}

func (m *Metrics) writePrometheus(w io.Writer) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, d := range counterDefs {
		fmt.Fprintf(w, "# HELP %s%s %s\n", metricPrefix, d.name, d.help)
		fmt.Fprintf(w, "# TYPE %s%s counter\n", metricPrefix, d.name)
		fmt.Fprintf(w, "%s%s%s %d\n", metricPrefix, d.name, m.labels, m.counters[d.name])
	}
	gauges := []struct {
		def   gaugeDef
		value int64
	}{
		{gaugeDefs[0], m.diverged},
		{gaugeDefs[1], m.wouldHeal},
		{gaugeDefs[2], m.writable},
	}
	for _, g := range gauges {
		fmt.Fprintf(w, "# HELP %s%s %s\n", metricPrefix, g.def.name, g.def.help)
		fmt.Fprintf(w, "# TYPE %s%s gauge\n", metricPrefix, g.def.name)
		fmt.Fprintf(w, "%s%s%s %d\n", metricPrefix, g.def.name, m.labels, g.value)
	}
}
