#!/usr/bin/env bash

set -euo pipefail

readonly SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEMP_PARENT="${TMPDIR:-/private/tmp}"
readonly TEMP_ROOT="$(mktemp -d "${TEMP_PARENT%/}/ghosttal-preflight.XXXXXX")"
readonly STAGE_ROOT="${TEMP_ROOT}/source"

cleanup() {
  case "${TEMP_ROOT}" in
    "${TEMP_PARENT%/}"/ghosttal-preflight.*) rm -rf -- "${TEMP_ROOT}" ;;
    *) echo "Refusing to remove unexpected temporary path: ${TEMP_ROOT}" >&2 ;;
  esac
}
trap cleanup EXIT

for command_name in zig nu xcodebuild lipo rsync; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

mkdir -p "${STAGE_ROOT}"
rsync -a \
  --exclude '/.git/' \
  --exclude '/.zig-cache/' \
  --exclude '/zig-out/' \
  --exclude '/zig-pkg/' \
  --exclude '/macos/build/' \
  "${SOURCE_ROOT}/" "${STAGE_ROOT}/"

cd "${STAGE_ROOT}"

release_version="${RELEASE_VERSION:-}"
if [[ -z "${release_version}" ]]; then
  settings="$(xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -target Ghostty \
    -configuration Release \
    -disableAutomaticPackageResolution \
    -showBuildSettings)"
  release_version="$(awk -F ' = ' \
    '$1 ~ "^[[:space:]]*MARKETING_VERSION$" { print $2; exit }' <<<"${settings}")"
fi
readonly release_version

[[ "${release_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Could not resolve an X.Y.Z release version." >&2
  exit 1
}
grep -Eq "^## ${release_version//./\\.}([[:space:]]|$)" CHANGELOG.md || {
  echo "CHANGELOG.md has no ${release_version} release section." >&2
  exit 1
}

./scripts/verify-macos-version-settings.sh "${release_version}"
zig build -Demit-macos-app=false -Doptimize=ReleaseFast
./macos/build.nu --scheme Ghostty --configuration Release --action build
./scripts/verify-macos-app.sh \
  "${STAGE_ROOT}/macos/build/Release/Ghosttal.app" \
  "${release_version}"

echo "Credential-free release preflight passed for Ghosttal ${release_version}."
