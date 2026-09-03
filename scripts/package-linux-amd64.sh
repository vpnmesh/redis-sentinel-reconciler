#!/usr/bin/env bash
# Build linux/amd64 tarball + .deb into dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --always --dirty 2>/dev/null || true)"
fi
VERSION="${VERSION:-0.0.0-dev}"
VERSION="${VERSION#v}"
# Debian upstream version: letters, digits, dot, plus, tilde, hyphen.
DEB_VERSION="$(printf '%s' "$VERSION" | sed 's/[^A-Za-z0-9.+~-]/+/g')"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo none)"

OUT="${OUT:-"$ROOT/dist"}"
NAME="redis-sentinel-reconciler"
TARBALL_STEM="${NAME}_${VERSION}_linux_amd64"
DEB_FILE="${NAME}_${DEB_VERSION}_amd64.deb"

rm -rf "$OUT/stage" "$OUT/debian"
mkdir -p "$OUT"

echo "building ${NAME} ${VERSION} (commit ${COMMIT}) linux/amd64"

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
  -o "$OUT/stage/${TARBALL_STEM}/reconciler" ./cmd/reconciler

install -m 0644 README.md "$OUT/stage/${TARBALL_STEM}/README.md"
install -d "$OUT/stage/${TARBALL_STEM}/systemd"
install -m 0644 deploy/systemd/redis-sentinel-reconciler.service \
  "$OUT/stage/${TARBALL_STEM}/systemd/redis-sentinel-reconciler.service"
install -m 0644 deploy/systemd/redis-sentinel-reconciler.default \
  "$OUT/stage/${TARBALL_STEM}/systemd/redis-sentinel-reconciler.default"

tar -C "$OUT/stage" -czf "$OUT/${TARBALL_STEM}.tar.gz" "${TARBALL_STEM}"

# --- deb ---
DEB_ROOT="$OUT/debian/${NAME}_${DEB_VERSION}_amd64"
install -d "$DEB_ROOT/DEBIAN"
install -d "$DEB_ROOT/usr/bin"
install -d "$DEB_ROOT/lib/systemd/system"
install -d "$DEB_ROOT/etc/default"
install -m 0755 "$OUT/stage/${TARBALL_STEM}/reconciler" "$DEB_ROOT/usr/bin/reconciler"
install -m 0644 deploy/systemd/redis-sentinel-reconciler.service \
  "$DEB_ROOT/lib/systemd/system/redis-sentinel-reconciler.service"
install -m 0640 deploy/systemd/redis-sentinel-reconciler.default \
  "$DEB_ROOT/etc/default/redis-sentinel-reconciler"
install -m 0755 packaging/deb/postinst "$DEB_ROOT/DEBIAN/postinst"
install -m 0755 packaging/deb/prerm "$DEB_ROOT/DEBIAN/prerm"
install -m 0755 packaging/deb/postrm "$DEB_ROOT/DEBIAN/postrm"
install -m 0644 packaging/deb/conffiles "$DEB_ROOT/DEBIAN/conffiles"

SIZE_KB="$(du -sk "$DEB_ROOT" | awk '{print $1}')"
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: ${NAME}
Version: ${DEB_VERSION}
Section: net
Priority: optional
Architecture: amd64
Maintainer: VpnMesh <github@vpnmesh.pro>
Installed-Size: ${SIZE_KB}
Depends: adduser
Recommends: redis-sentinel | redis-server
Homepage: https://github.com/vpnmesh/redis-sentinel-reconciler
Description: Sidecar that heals Redis/Valkey Sentinel master advertisements
 Observes (and optionally repairs) Sentinel get-master-addr when it
 disagrees with the writable Redis data plane. Default is dry-run.
EOF

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb not found; tarball only: $OUT/${TARBALL_STEM}.tar.gz" >&2
else
  dpkg-deb --root-owner-group --build "$DEB_ROOT" "$OUT/${DEB_FILE}"
fi

( cd "$OUT" && {
  if [[ -f "$DEB_FILE" ]]; then
    sha256sum "${TARBALL_STEM}.tar.gz" "$DEB_FILE"
  else
    sha256sum "${TARBALL_STEM}.tar.gz"
  fi
} >sha256sums.txt )

rm -rf "$OUT/stage" "$OUT/debian"
echo "wrote $OUT/${TARBALL_STEM}.tar.gz"
[[ -f "$OUT/${DEB_FILE}" ]] && echo "wrote $OUT/${DEB_FILE}"
echo "wrote $OUT/sha256sums.txt"
