# Hazard e2e (H1-H10)

See [docs/operations.md](../../docs/operations.md).

Each `H*.sh` has:

1. **PHASE A** - naive Sentinel API / herd (what unsafe `--apply` would do) -> prove outage or cemented split
2. **PHASE B** - reconciler with countermeasures -> `apply_refused` / safe heal / CLI reject

```bash
cd redis-sentinel-reconciler
make e2e-hazards
# or:
./lab/e2e/hazards/run.sh
```

Some cases (H6 election window, H7 AUTH, H9 equal-epoch) may **SKIP** in lab when the race cannot be held; unit tests in `internal/reconcile/*_test.go` remain binding for those guards.
