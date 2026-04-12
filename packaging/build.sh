#!/usr/bin/env bash
# Build .rpm and .deb packages of termigate using fpm.
#
# Requirements:
#   - Elixir/Erlang toolchain (to build the release)
#   - fpm (https://fpm.readthedocs.io) — install via the bundled Gemfile:
#       cd packaging && bundle install
#     Or globally:
#       gem install --no-document fpm
#   - rpmbuild (for .rpm output) — package name varies: rpm / rpm-build
#   - dpkg-deb (for .deb output) — usually preinstalled on Debian/Ubuntu
#
# Usage:
#   ./packaging/build.sh            # builds both rpm and deb
#   ./packaging/build.sh rpm        # rpm only
#   ./packaging/build.sh deb        # deb only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="${REPO_ROOT}/server"
PKG_DIR="${REPO_ROOT}/packaging"
STAGING="${PKG_DIR}/staging"
OUT_DIR="${PKG_DIR}/out"

# Pull version from mix.exs
VERSION="$(grep -oP '(?<=version: ")[^"]+' "${SERVER_DIR}/mix.exs" | head -n1)"
if [[ -z "${VERSION}" ]]; then
  echo "ERROR: could not determine version from ${SERVER_DIR}/mix.exs" >&2
  exit 1
fi

ARCH_RPM="$(uname -m)"
case "${ARCH_RPM}" in
  x86_64)  ARCH_DEB="amd64" ;;
  aarch64) ARCH_DEB="arm64" ;;
  *)       ARCH_DEB="${ARCH_RPM}" ;;
esac

echo "=> termigate ${VERSION} (${ARCH_RPM}/${ARCH_DEB})"

# Prefer bundle exec fpm if a Gemfile + lockfile are present.
if [[ -f "${PKG_DIR}/Gemfile.lock" ]] && command -v bundle > /dev/null 2>&1; then
  FPM=(bundle exec --gemfile "${PKG_DIR}/Gemfile" fpm)
else
  FPM=(fpm)
fi

# ---- 1. Build the mix release ----
echo "=> building mix release"
pushd "${SERVER_DIR}" > /dev/null
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
popd > /dev/null

# ---- 2. Stage the filesystem layout ----
echo "=> staging files"
rm -rf "${STAGING}"
mkdir -p \
  "${STAGING}/usr/lib/termigate" \
  "${STAGING}/usr/bin" \
  "${STAGING}/usr/lib/systemd/system" \
  "${STAGING}/etc/termigate" \
  "${STAGING}/var/lib/termigate"

cp -a "${SERVER_DIR}/_build/prod/rel/termigate/." "${STAGING}/usr/lib/termigate/"
ln -sf /usr/lib/termigate/bin/termigate "${STAGING}/usr/bin/termigate"
cp "${REPO_ROOT}/deploy/termigate.service" "${STAGING}/usr/lib/systemd/system/termigate.service"
cp "${PKG_DIR}/config.example.yaml" "${STAGING}/etc/termigate/config.example.yaml"

# ---- 3. Common fpm args ----
mkdir -p "${OUT_DIR}"

COMMON_ARGS=(
  --name termigate
  --version "${VERSION}"
  --license "MIT"
  --vendor "termigate"
  --maintainer "termigate <noreply@localhost>"
  --description "Browser-based tmux session manager with real-time terminal streaming."
  --url "https://github.com/anthropics/termigate"
  --input-type dir
  --chdir "${STAGING}"
  --prefix "/"
  --after-install   "${PKG_DIR}/scriptlets/postinst"
  --before-remove   "${PKG_DIR}/scriptlets/prerm"
  --after-remove    "${PKG_DIR}/scriptlets/postrm"
  --before-install  "${PKG_DIR}/scriptlets/preinst"
  --config-files    "/etc/termigate/config.example.yaml"
  --config-files    "/usr/lib/systemd/system/termigate.service"
)

build_rpm() {
  echo "=> building RPM"
  "${FPM[@]}" \
    "${COMMON_ARGS[@]}" \
    --output-type rpm \
    --architecture "${ARCH_RPM}" \
    --depends "tmux >= 3.1" \
    --depends "openssl-libs" \
    --depends "ncurses-libs" \
    --rpm-summary "Browser-based tmux session manager" \
    --package "${OUT_DIR}/termigate-${VERSION}-1.${ARCH_RPM}.rpm" \
    usr etc var
}

build_deb() {
  echo "=> building DEB"
  "${FPM[@]}" \
    "${COMMON_ARGS[@]}" \
    --output-type deb \
    --architecture "${ARCH_DEB}" \
    --depends "tmux (>= 3.1)" \
    --depends "libssl3 | libssl1.1" \
    --depends "libncurses6" \
    --deb-no-default-config-files \
    --package "${OUT_DIR}/termigate_${VERSION}_${ARCH_DEB}.deb" \
    usr etc var
}

case "${1:-all}" in
  rpm) build_rpm ;;
  deb) build_deb ;;
  all) build_rpm; build_deb ;;
  *)   echo "Unknown target: ${1}" >&2; exit 2 ;;
esac

echo
echo "=> done. Packages in: ${OUT_DIR}"
ls -la "${OUT_DIR}"
