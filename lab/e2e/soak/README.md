# Soak

`--apply` MONITOR flap for `SOAK_MINUTES` wall-clock (default 60, ~2 flaps/min).
`SOAK_ROUNDS=N` skips the wall and runs N flaps (short GATE). Not a production
dwell.

```bash
SOAK_MINUTES=60 make e2e-soak
SOAK_ROUNDS=4 make e2e-soak   # short GATE
```
