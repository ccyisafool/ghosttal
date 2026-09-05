#!/usr/bin/env bash

set -euo pipefail

readonly APP_PATH="${1:-}"
readonly EXPECTED_VERSION="${2:-}"

[[ -d "${APP_PATH}" && "${EXPECTED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: $0 /path/to/Ghosttal.app X.Y.Z" >&2
  exit 1
}

readonly PLIST_BUDDY=/usr/libexec/PlistBuddy
readonly APP_INFO="${APP_PATH}/Contents/Info.plist"
readonly APP_BINARY="${APP_PATH}/Contents/MacOS/ghosttal"
readonly PLUGIN_PATH="${APP_PATH}/Contents/PlugIns/DockTilePlugin.plugin"
readonly PLUGIN_INFO="${PLUGIN_PATH}/Contents/Info.plist"
readonly PLUGIN_BINARY="${PLUGIN_PATH}/Contents/MacOS/DockTilePlugin"

for required_path in \
  "${APP_INFO}" \
  "${APP_BINARY}" \
  "${PLUGIN_INFO}" \
  "${PLUGIN_BINARY}"; do
  [[ -e "${required_path}" ]] || {
    echo "Required release artifact is missing: ${required_path}" >&2
    exit 1
  }
done

verify_bundle_version() {
  local label="$1"
  local plist="$2"
  local short_version build_version
  short_version="$("${PLIST_BUDDY}" -c 'Print :CFBundleShortVersionString' "${plist}")"
  build_version="$("${PLIST_BUDDY}" -c 'Print :CFBundleVersion' "${plist}")"
  [[ "${short_version}" == "${EXPECTED_VERSION}" && "${build_version}" == "${EXPECTED_VERSION}" ]] || {
    echo "${label} version ${short_version} (${build_version}) does not match ${EXPECTED_VERSION}." >&2
    exit 1
  }
}

verify_universal_binary() {
  local label="$1"
  local binary="$2"
  local archs
  archs="$(lipo -archs "${binary}")"
  [[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]] || {
    echo "${label} is not universal; found architectures: ${archs}" >&2
    exit 1
  }
  echo "${label} architectures: ${archs}"
}

verify_bundle_version "Ghosttal.app" "${APP_INFO}"
verify_bundle_version "DockTilePlugin.plugin" "${PLUGIN_INFO}"
verify_universal_binary "Ghosttal.app" "${APP_BINARY}"
verify_universal_binary "DockTilePlugin.plugin" "${PLUGIN_BINARY}"

echo "Ghosttal ${EXPECTED_VERSION} app bundle is structurally valid."
