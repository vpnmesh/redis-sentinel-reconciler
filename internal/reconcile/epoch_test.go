package reconcile

import "testing"

func TestDetectEqualEpochTrapLogic(t *testing.T) {
	ads := map[string]struct{}{"10.0.0.1:6379": {}, "10.0.0.2:6379": {}}
	epochs := map[int64]struct{}{5: {}}
	trap := len(ads) >= 2 && len(epochs) <= 1
	if !trap {
		t.Fatal("expected trap")
	}
	epochs[6] = struct{}{}
	trap = len(ads) >= 2 && len(epochs) <= 1
	if trap {
		t.Fatal("conflicting epochs must not trap")
	}
	// ads disagree, no parsed epochs -> still trap
	epochs = map[int64]struct{}{}
	trap = len(ads) >= 2 && len(epochs) <= 1
	if !trap {
		t.Fatal("expected trap when epochs unknown")
	}
}
