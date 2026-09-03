package oracle

import "testing"

func TestClassifyWritable(t *testing.T) {
	nodes := []NodeResult{
		{Addr: "a:6379", Role: "slave", Writable: false},
		{Addr: "b:6379", Role: "master", Writable: true, RunID: "run-b"},
		{Addr: "c:6379", Role: "master", Writable: true, RunID: "run-c"},
	}
	w, count := ClassifyWritable(nodes)
	if count != 2 || w == nil || w.Addr != "b:6379" {
		t.Fatalf("got writable=%v count=%d", w, count)
	}

	// Same physical master via hostname + IP must count once.
	w, count = ClassifyWritable([]NodeResult{
		{Addr: "redis-1:6379", Role: "master", Writable: true, RunID: "same"},
		{Addr: "172.27.0.2:6379", Role: "master", Writable: true, RunID: "same"},
	})
	if count != 1 || w == nil {
		t.Fatalf("expected deduped single master, got %v count=%d", w, count)
	}

	w, count = ClassifyWritable([]NodeResult{{Addr: "x:6379", Role: "master", Writable: false}})
	if count != 0 || w != nil {
		t.Fatalf("expected no writable master, got %v count=%d", w, count)
	}
}
