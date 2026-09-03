package reconcile

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func scrape(t *testing.T, m *Metrics) string {
	t.Helper()
	rec := httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != 200 {
		t.Fatalf("status %d", rec.Code)
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/plain") || !strings.Contains(ct, "version=0.0.4") {
		t.Fatalf("content-type %q", ct)
	}
	return rec.Body.String()
}

func TestMetrics_RegisteredAtZeroWithHelpType(t *testing.T) {
	m := newMetrics("mymaster", false)
	body := scrape(t, m)
	for _, name := range []string{
		"redis_sentinel_reconciler_ticks_total",
		"redis_sentinel_reconciler_diverge_total",
		"redis_sentinel_reconciler_would_heal_total",
		"redis_sentinel_reconciler_heal_ok_total",
		"redis_sentinel_reconciler_heal_fail_total",
		"redis_sentinel_reconciler_apply_refused_total",
		"redis_sentinel_reconciler_alert_dual_master_total",
		"redis_sentinel_reconciler_alert_equal_epoch_trap_total",
		"redis_sentinel_reconciler_alert_equal_epoch_escalate_total",
		"redis_sentinel_reconciler_noop_total",
		"redis_sentinel_reconciler_heal_attempt_total",
		"redis_sentinel_reconciler_heal_lease_acquired_total",
		"redis_sentinel_reconciler_alert_no_redis_total",
		"redis_sentinel_reconciler_alert_no_writable_total",
	} {
		if !strings.Contains(body, "# HELP "+name+" ") {
			t.Errorf("missing HELP %s", name)
		}
		if !strings.Contains(body, "# TYPE "+name+" counter") {
			t.Errorf("missing TYPE counter %s", name)
		}
		if !strings.Contains(body, name+`{master_name="mymaster",apply="false"} 0`) {
			t.Errorf("missing zero sample %s\n%s", name, body)
		}
	}
	for _, name := range []string{
		"redis_sentinel_reconciler_diverged",
		"redis_sentinel_reconciler_would_heal",
		"redis_sentinel_reconciler_writable_masters",
	} {
		if !strings.Contains(body, "# TYPE "+name+" gauge") {
			t.Errorf("missing TYPE gauge %s", name)
		}
		if !strings.Contains(body, name+`{master_name="mymaster",apply="false"} 0`) {
			t.Errorf("missing zero gauge %s", name)
		}
	}
	if strings.Contains(body, "redis_sentinel_reconciler_diverge ") && !strings.Contains(body, "diverge_total") {
		t.Fatal("old counter name without _total must not be the only sample")
	}
}

func TestMetrics_ScrapeDoesNotIncrement(t *testing.T) {
	m := newMetrics("prod", true)
	m.Inc("diverge")
	m.NoteDiverged()
	m.SetWritableMasters(1)
	first := scrape(t, m)
	second := scrape(t, m)
	want := `redis_sentinel_reconciler_diverge_total{master_name="prod",apply="true"} 1`
	if strings.Count(first, want) != 1 || strings.Count(second, want) != 1 {
		t.Fatalf("scrape mutated counter\nfirst:\n%s\nsecond:\n%s", first, second)
	}
	if !strings.Contains(second, `redis_sentinel_reconciler_diverged{master_name="prod",apply="true"} 1`) {
		t.Fatal("gauge diverged")
	}
}

func TestMetrics_IncAndGaugesAreTickNotScrape(t *testing.T) {
	m := newMetrics("mymaster", false)
	m.ResetTickGauges()
	m.Inc("ticks")
	m.Inc("diverge")
	m.Inc("would_heal")
	m.NoteDiverged()
	m.NoteWouldHeal()
	m.SetWritableMasters(1)
	body := scrape(t, m)
	for _, line := range []string{
		`redis_sentinel_reconciler_ticks_total{master_name="mymaster",apply="false"} 1`,
		`redis_sentinel_reconciler_diverge_total{master_name="mymaster",apply="false"} 1`,
		`redis_sentinel_reconciler_would_heal_total{master_name="mymaster",apply="false"} 1`,
		`redis_sentinel_reconciler_diverged{master_name="mymaster",apply="false"} 1`,
		`redis_sentinel_reconciler_would_heal{master_name="mymaster",apply="false"} 1`,
		`redis_sentinel_reconciler_writable_masters{master_name="mymaster",apply="false"} 1`,
	} {
		if !strings.Contains(body, line) {
			t.Errorf("missing %s\n%s", line, body)
		}
	}
	m.ResetTickGauges()
	body = scrape(t, m)
	if !strings.Contains(body, `redis_sentinel_reconciler_diverge_total{master_name="mymaster",apply="false"} 1`) {
		t.Fatal("counter must survive gauge reset")
	}
	if !strings.Contains(body, `redis_sentinel_reconciler_diverged{master_name="mymaster",apply="false"} 0`) {
		t.Fatal("gauge must clear on next tick start")
	}
}

func TestMetrics_UnknownIncIgnored(t *testing.T) {
	m := newMetrics("mymaster", false)
	m.Inc("not_a_real_metric")
	var buf strings.Builder
	m.writePrometheus(&buf)
	if strings.Contains(buf.String(), "not_a_real_metric") {
		t.Fatal("sparse unknown names must not appear")
	}
}

func TestMetrics_WriteDoesNotUseExpvarSideEffects(t *testing.T) {
	m := newMetrics("mymaster", false)
	m.writePrometheus(io.Discard)
	m.writePrometheus(io.Discard)
}
