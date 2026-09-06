#!/usr/bin/env bash
# Lab CA + leaf certs for redis.lab / sentinel.lab (compose network aliases).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${TLS_CERT_DIR:-$DIR/certs}"
mkdir -p "$OUT"

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: need $1"; exit 1; }; }
need openssl

if [[ -f "$OUT/ca.pem" && -f "$OUT/redis.lab.pem" && -f "$OUT/sentinel.lab.pem" && "${TLS_REGEN:-0}" != "1" ]]; then
  echo "certs already in $OUT (TLS_REGEN=1 to rebuild)"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
  -subj "/CN=rsr-lab-ca" \
  -keyout "$OUT/ca-key.pem" -out "$OUT/ca.pem" 2>/dev/null

leaf() {
  local name="$1" ip="$2"
  openssl req -newkey rsa:2048 -nodes \
    -subj "/CN=${name}" \
    -keyout "$OUT/${name}-key.pem" -out "$OUT/${name}.csr" 2>/dev/null
  openssl x509 -req -in "$OUT/${name}.csr" \
    -CA "$OUT/ca.pem" -CAkey "$OUT/ca-key.pem" -CAcreateserial \
    -out "$OUT/${name}.pem" -days 2 -sha256 \
    -extfile <(printf 'subjectAltName=DNS:%s,IP:%s\n' "$name" "$ip") 2>/dev/null
  rm -f "$OUT/${name}.csr"
  chmod 644 "$OUT/${name}.pem" "$OUT/${name}-key.pem"
}

leaf redis.lab 172.30.90.10
leaf sentinel.lab 172.30.90.11
chmod 644 "$OUT/ca.pem"
rm -f "$OUT/ca.srl" "$OUT/ca-key.pem"
echo "wrote $OUT/{ca,redis.lab,sentinel.lab}.pem"
