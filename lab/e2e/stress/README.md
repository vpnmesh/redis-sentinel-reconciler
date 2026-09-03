# Short stress

Not a soak. About 3–8 minutes on a warm lab, 10–15 with `E2E_RESET=1`.

```bash
make e2e-stress
STRESS_ROUNDS=12 make e2e-stress
```

| Case | Checks |
|------|--------|
| S1 | MONITOR flap ×N → guarded heal, one writable, writer still works |
| S2 | Five parallel apply attempts → no dual writable |
| S3 | Dual master ×5 ticks → refuse only |
| S4 | Parallel apply with `--heal-lease` → one holder |
