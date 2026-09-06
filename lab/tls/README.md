# TLS lab

One Redis + one Sentinel, `tls-port` only. Reconciler dials with `--tls`
and `--tls-ca-file`, then `--apply --once` heals a fake MONITOR.

```bash
make e2e-tls
```

Needs `openssl`, Docker Compose v2. Certs are generated under `certs/`
(gitignored `*.pem`).
