package reconcile

import (
	"expvar"
	"fmt"
	"net/http"
	"sync"
)

// Metrics is a tiny process-local counter set (Prometheus text via /metrics).
type Metrics struct {
	mu   sync.Mutex
	data map[string]int64
}

func newMetrics() *Metrics {
	return &Metrics{data: map[string]int64{}}
}

func (m *Metrics) Inc(name string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.data[name]++
	m.mu.Unlock()
}

func (m *Metrics) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		m.mu.Lock()
		defer m.mu.Unlock()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		for k, v := range m.data {
			fmt.Fprintf(w, "redis_sentinel_reconciler_%s %d\n", k, v)
		}
		// Also expose via expvar for casual debugging.
		_ = expvar.Get("reconciler")
	})
}
