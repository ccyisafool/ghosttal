#!/usr/bin/env bash

set -euo pipefail

readonly SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RELEASE_VERSION="${RELEASE_VERSION:-0.1.2}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Chenyang Cheng (Y63C8FW5ZK)}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-${SOURCE_ROOT}/dist}"
readonly APPCAST_PATH="${APPCAST_PATH:-${SOURCE_ROOT}/appcast.xml}"
readonly DOWNLOAD_URL_BASE="https://github.com/ccyisafool/ghosttal/releases/download/v${RELEASE_VERSION}"
readonly RELEASE_NOTES_URL="https://github.com/ccyisafool/ghosttal/releases/tag/v${RELEASE_VERSION}"
readonly MINIMUM_SYSTEM_VERSION="13.0"
readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/ghosttal-release.XXXXXX")"
readonly STAGE_ROOT="${TEMP_ROOT}/source"
readonly APP_PATH="${STAGE_ROOT}/macos/build/Release/Ghosttal.app"
readonly DMG_NAME="Ghosttal-${RELEASE_VERSION}-universal.dmg"
readonly DMG_SOURCE="${TEMP_ROOT}/dmg"
readonly DMG_MOUNT="${TEMP_ROOT}/mount"
readonly STAGED_DMG="${TEMP_ROOT}/${DMG_NAME}"

cleanup() {
  hdiutil detach "${DMG_MOUNT}" >/dev/null 2>&1 || true

  if [[ "${TEMP_ROOT}" == /private/tmp/ghosttal-release.* || "${TEMP_ROOT}" == /tmp/ghosttal-release.* ]]; then
    rm -rf -- "${TEMP_ROOT}"
  fi
}
trap cleanup EXIT

retry() {
  local max_attempts="$1"
  shift
  local attempt=1

  until "$@"; do
    if (( attempt >= max_attempts )); then
      return 1
    fi

    echo "Command failed; retrying (${attempt}/${max_attempts}): $*" >&2
    sleep 30
    ((attempt += 1))
  done
}

for command_name in zig nu xcodebuild codesign hdiutil xcrun lipo rsync ditto ln readlink; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

# Notary credentials live in the data-protection keychain, so probe via
# notarytool itself. Machines store the profile under different names.
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  for candidate in ghosttal-notary notarytool; do
    if xcrun notarytool history --keychain-profile "${candidate}" >/dev/null 2>&1; then
      NOTARY_PROFILE="${candidate}"
      break
    fi
  done
  [[ -n "${NOTARY_PROFILE:-}" ]] || {
    echo "No notary credential profile found (tried: ghosttal-notary, notarytool)." >&2
    echo "Run: xcrun notarytool store-credentials <profile> --apple-id <id> --team-id Y63C8FW5ZK" >&2
    exit 1
  }
fi
readonly NOTARY_PROFILE
echo "Using notary profile: ${NOTARY_PROFILE}"

# Sparkle's CLI tools ship with the SPM artifact checkout.
if [[ -z "${SPARKLE_BIN:-}" ]]; then
  SPARKLE_BIN="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -type d -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)"
fi
[[ -n "${SPARKLE_BIN}" && -x "${SPARKLE_BIN}/sign_update" ]] || {
  echo "Sparkle tools not found; set SPARKLE_BIN to the Sparkle bin directory." >&2
  exit 1
}
readonly SPARKLE_BIN

# The app's Info.plist version keys must match the release version, or Sparkle
# will not recognize published updates as newer than installed builds.
grep -Fq "MARKETING_VERSION = ${RELEASE_VERSION};" "${SOURCE_ROOT}/macos/Ghostty.xcodeproj/project.pbxproj" || {
  echo "MARKETING_VERSION in project.pbxproj does not match RELEASE_VERSION=${RELEASE_VERSION}" >&2
  exit 1
}
grep -Fq "CURRENT_PROJECT_VERSION = ${RELEASE_VERSION};" "${SOURCE_ROOT}/macos/Ghostty.xcodeproj/project.pbxproj" || {
  echo "CURRENT_PROJECT_VERSION in project.pbxproj does not match RELEASE_VERSION=${RELEASE_VERSION}" >&2
  exit 1
}

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

retry 20 codesign --force --deep --options runtime --timestamp \
  --entitlements "${STAGE_ROOT}/macos/Ghostty.entitlements" \
  --sign "${SIGNING_IDENTITY}" \
  "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

mkdir -p "${DMG_SOURCE}" "${DMG_MOUNT}"
ditto --rsrc --extattr "${APP_PATH}" "${DMG_SOURCE}/Ghosttal.app"
ln -s /Applications "${DMG_SOURCE}/Applications"

hdiutil create \
  -volname Ghosttal \
  -srcfolder "${DMG_SOURCE}" \
  -format UDZO \
  -ov \
  "${STAGED_DMG}"

hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "${DMG_MOUNT}" \
  "${STAGED_DMG}"
[[ -d "${DMG_MOUNT}/Ghosttal.app" ]] || {
  echo "DMG is missing Ghosttal.app" >&2
  exit 1
}
[[ -L "${DMG_MOUNT}/Applications" && "$(readlink "${DMG_MOUNT}/Applications")" == /Applications ]] || {
  echo "DMG is missing the /Applications shortcut" >&2
  exit 1
}
hdiutil detach "${DMG_MOUNT}"

retry 20 codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${STAGED_DMG}"
codesign --verify --verbose=2 "${STAGED_DMG}"

xcrun notarytool submit "${STAGED_DMG}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait
retry 20 xcrun stapler staple "${STAGED_DMG}"
xcrun stapler validate "${STAGED_DMG}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${STAGED_DMG}"

ditto --rsrc --extattr "${STAGED_DMG}" "${OUTPUT_DIR}/${DMG_NAME}"

# Sign the DMG with Ghosttal's Sparkle EdDSA key and regenerate the appcast
# that shipped apps poll (served from the repository's main branch).
ED_ATTRIBUTES="$("${SPARKLE_BIN}/sign_update" "${OUTPUT_DIR}/${DMG_NAME}")"
[[ "${ED_ATTRIBUTES}" == *sparkle:edSignature=* ]] || {
  echo "sign_update did not produce an EdDSA signature: ${ED_ATTRIBUTES}" >&2
  exit 1
}

cat > "${APPCAST_PATH}" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ghosttal</title>
    <link>https://github.com/ccyisafool/ghosttal</link>
    <description>Ghosttal update feed</description>
    <language>en</language>
    <item>
      <title>Ghosttal ${RELEASE_VERSION}</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${RELEASE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${RELEASE_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>
      <enclosure url="${DOWNLOAD_URL_BASE}/${DMG_NAME}" ${ED_ATTRIBUTES} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST

echo "Release ready: ${OUTPUT_DIR}/${DMG_NAME}"
echo "Architectures: ${APP_ARCHS}"
echo "Appcast updated: ${APPCAST_PATH}"
echo
echo "To publish this release:"
echo "  1. Commit the appcast (and version bumps), then push main."
echo "  2. Tag: git tag v${RELEASE_VERSION} && git push origin v${RELEASE_VERSION}"
echo "  3. Publish: gh release create v${RELEASE_VERSION} '${OUTPUT_DIR}/${DMG_NAME}' --title 'Ghosttal ${RELEASE_VERSION}'"
echo "  (Publish the GitHub release BEFORE pushing the appcast commit, or"
echo "   shipped apps may briefly see an enclosure URL that 404s.)"
