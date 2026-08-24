#!/usr/bin/env bash

set -euo pipefail

readonly SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RELEASE_VERSION="${RELEASE_VERSION:-0.1.0}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Chenyang Cheng (Y63C8FW5ZK)}"
readonly NOTARY_PROFILE="${NOTARY_PROFILE:-ghosttal-notary}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-${SOURCE_ROOT}/dist}"
readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/ghosttal-release.XXXXXX")"
readonly STAGE_ROOT="${TEMP_ROOT}/source"
readonly APP_PATH="${STAGE_ROOT}/macos/build/Release/Ghosttal.app"
readonly DMG_NAME="Ghosttal-${RELEASE_VERSION}-universal.dmg"
readonly STAGED_DMG="${TEMP_ROOT}/${DMG_NAME}"

cleanup() {
  if [[ "${TEMP_ROOT}" == /private/tmp/ghosttal-release.* || "${TEMP_ROOT}" == /tmp/ghosttal-release.* ]]; then
    rm -rf -- "${TEMP_ROOT}"
  fi
}
trap cleanup EXIT

for command_name in zig nu xcodebuild codesign hdiutil xcrun lipo rsync; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

security find-identity -v -p codesigning | grep -Fq "${SIGNING_IDENTITY}" || {
  echo "Signing identity is unavailable: ${SIGNING_IDENTITY}" >&2
  exit 1
}

mkdir -p "${STAGE_ROOT}" "${OUTPUT_DIR}"
rsync -a \
  --exclude .git \
  --exclude .zig-cache \
  --exclude zig-cache \
  --exclude zig-out \
  --exclude zig-pkg \
  --exclude macos/build \
  --exclude macos/GhosttyKit.xcframework \
  --exclude '*.key' \
  --exclude '*.csr' \
  --exclude '*.p12' \
  "${SOURCE_ROOT}/" "${STAGE_ROOT}/"

cd "${STAGE_ROOT}"

zig build -Demit-macos-app=false -Doptimize=ReleaseFast
./macos/build.nu --scheme Ghostty --configuration Release --action build

[[ -d "${APP_PATH}" ]] || {
  echo "Release app was not produced at ${APP_PATH}" >&2
  exit 1
}

readonly APP_ARCHS="$(lipo -archs "${APP_PATH}/Contents/MacOS/ghosttal")"
[[ " ${APP_ARCHS} " == *" arm64 "* && " ${APP_ARCHS} " == *" x86_64 "* ]] || {
  echo "Expected a universal app; found architectures: ${APP_ARCHS}" >&2
  exit 1
}

codesign --force --deep --options runtime --timestamp \
  --entitlements "${STAGE_ROOT}/macos/Ghostty.entitlements" \
  --sign "${SIGNING_IDENTITY}" \
  "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

hdiutil create \
  -volname Ghosttal \
  -srcfolder "${APP_PATH}" \
  -format UDZO \
  -ov \
  "${STAGED_DMG}"
codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${STAGED_DMG}"
codesign --verify --verbose=2 "${STAGED_DMG}"

xcrun notarytool submit "${STAGED_DMG}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait
xcrun stapler staple "${STAGED_DMG}"
xcrun stapler validate "${STAGED_DMG}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${STAGED_DMG}"

cp "${STAGED_DMG}" "${OUTPUT_DIR}/${DMG_NAME}"

echo "Release ready: ${OUTPUT_DIR}/${DMG_NAME}"
echo "Architectures: ${APP_ARCHS}"
