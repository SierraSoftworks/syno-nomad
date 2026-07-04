#!/usr/bin/env bash
# Build a Synology package (.spk) for HashiCorp Nomad.
#
# Usage: ./build.sh <nomad-version> <x86_64|aarch64> [revision]
#
# Downloads the official Nomad release binary (verifying its SHA256 checksum),
# assembles package.tgz and the surrounding SPK metadata, and writes
# dist/nomad-<version>-<revision>-<arch>.spk
set -euo pipefail

NOMAD_VERSION="${1:?usage: build.sh <nomad-version> <x86_64|aarch64> [revision]}"
SYNO_ARCH="${2:?usage: build.sh <nomad-version> <x86_64|aarch64> [revision]}"
REVISION="${3:-1}"

case "$SYNO_ARCH" in
    x86_64) NOMAD_ARCH="amd64" ;;
    aarch64) NOMAD_ARCH="arm64" ;;
    *)
        echo "Unsupported architecture: ${SYNO_ARCH} (expected x86_64 or aarch64)" >&2
        exit 1
        ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${ROOT}/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# GNU tar and bsdtar (macOS) take different flags for forcing root ownership.
TAR="tar"
command -v gtar > /dev/null && TAR="gtar"
if "$TAR" --version 2> /dev/null | grep -q "GNU tar"; then
    TAR_OWNER=(--owner=0 --group=0 --numeric-owner)
else
    TAR_OWNER=(--uid 0 --gid 0)
fi

sha256_check() {
    if command -v sha256sum > /dev/null; then
        sha256sum -c -
    else
        shasum -a 256 -c -
    fi
}

md5_of() {
    if command -v md5sum > /dev/null; then
        md5sum "$1" | awk '{print $1}'
    else
        md5 -q "$1"
    fi
}

echo "==> Downloading Nomad ${NOMAD_VERSION} (linux/${NOMAD_ARCH})"
BASE_URL="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}"
ZIP="nomad_${NOMAD_VERSION}_linux_${NOMAD_ARCH}.zip"
curl -fsSL --retry 3 -o "${WORK}/${ZIP}" "${BASE_URL}/${ZIP}"
curl -fsSL --retry 3 -o "${WORK}/SHA256SUMS" "${BASE_URL}/nomad_${NOMAD_VERSION}_SHA256SUMS"
(cd "$WORK" && grep " ${ZIP}\$" SHA256SUMS | sha256_check)

unzip -qo "${WORK}/${ZIP}" -d "${WORK}/unpacked"

echo "==> Assembling package.tgz"
PAYLOAD="${WORK}/payload"
mkdir -p "${PAYLOAD}/bin"
cp -R "${ROOT}/spk/package/." "$PAYLOAD/"
cp "${WORK}/unpacked/nomad" "${PAYLOAD}/bin/nomad"
chmod 0755 "${PAYLOAD}/bin/nomad"
chmod 0755 "${PAYLOAD}"/share/*.sh

SPKROOT="${WORK}/spkroot"
mkdir -p "$SPKROOT"
"$TAR" "${TAR_OWNER[@]}" -czf "${SPKROOT}/package.tgz" -C "$PAYLOAD" .

echo "==> Assembling SPK metadata"
PKG_VERSION="${NOMAD_VERSION}-${REVISION}"
CHECKSUM="$(md5_of "${SPKROOT}/package.tgz")"
sed \
    -e "s/@PKG_VERSION@/${PKG_VERSION}/" \
    -e "s/@SPK_ARCH@/${SYNO_ARCH}/" \
    -e "s/@CHECKSUM@/${CHECKSUM}/" \
    "${ROOT}/spk/INFO.in" > "${SPKROOT}/INFO"

cp -R "${ROOT}/spk/scripts" "${SPKROOT}/scripts"
cp -R "${ROOT}/spk/conf" "${SPKROOT}/conf"
cp -R "${ROOT}/spk/WIZARD_UIFILES" "${SPKROOT}/WIZARD_UIFILES"
cp "${ROOT}/spk/PACKAGE_ICON.PNG" "${ROOT}/spk/PACKAGE_ICON_256.PNG" "$SPKROOT/"
chmod 0755 "${SPKROOT}/scripts/"*

mkdir -p "$DIST"
SPK="${DIST}/nomad-${PKG_VERSION}-${SYNO_ARCH}.spk"
"$TAR" "${TAR_OWNER[@]}" -cf "$SPK" -C "$SPKROOT" \
    INFO package.tgz scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG

echo "==> Built ${SPK}"
