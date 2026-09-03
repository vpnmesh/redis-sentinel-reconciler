# Live verify (R1–R22)

Exercises Redis, Sentinel, and `reconciler`, then writes evidence under
`lab/e2e/artifacts/readiness/`.

```bash
make e2e-readiness
```

Some rows only check that the matching section still exists in
`docs/configuration.md` / `docs/operations.md` / `docs/install.md`.
R19 is an honest skip: one `--master-name` per process.
