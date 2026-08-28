#!/usr/bin/env bash

set -euo pipefail

readonly SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Chenyang Cheng (Y63C8FW5ZK)}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-${SOURCE_ROOT}/dist}"
readonly APPCAST_PATH="${APPCAST_PATH:-${SOURCE_ROOT}/appcast.xml}"
readonly MINIMUM_SYSTEM_VERSION="13.0"
readonly RELEASE_VERSION="${RELEASE_VERSION:-}"

[[ "${RELEASE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Set RELEASE_VERSION to an X.Y.Z version." >&2
  exit 1
}

readonly RELEASE_TAG="v${RELEASE_VERSION}"
readonly DOWNLOAD_URL_BASE="https://github.com/ccyisafool/ghosttal/releases/download/${RELEASE_TAG}"
readonly RELEASE_NOTES_URL="https://github.com/ccyisafool/ghosttal/releases/tag/${RELEASE_TAG}"
readonly TEMP_PARENT="${TMPDIR:-/private/tmp}"
readonly TEMP_ROOT="$(mktemp -d "${TEMP_PARENT%/}/ghosttal-release.XXXXXX")"
readonly STAGE_ROOT="${TEMP_ROOT}/source"
readonly APP_PATH="${STAGE_ROOT}/macos/build/Release/Ghosttal.app"
readonly DMG_NAME="Ghosttal-${RELEASE_VERSION}-universal.dmg"
readonly DMG_SOURCE="${TEMP_ROOT}/dmg"
readonly DMG_MOUNT="${TEMP_ROOT}/mount"
readonly STAGED_DMG="${TEMP_ROOT}/${DMG_NAME}"
readonly CREATE_DMG="${CREATE_DMG:-create-dmg}"

cleanup() {
  hdiutil detach "${DMG_MOUNT}" >/dev/null 2>&1 || true
  case "${TEMP_ROOT}" in
    "${TEMP_PARENT%/}"/ghosttal-release.*) rm -rf -- "${TEMP_ROOT}" ;;
    *) echo "Refusing to remove unexpected temporary path: ${TEMP_ROOT}" >&2 ;;
  esac
}
trap cleanup EXIT

retry() {
  local max_attempts="$1"
  shift
  local attempt=1
  until "$@"; do
    if (( attempt >= max_attempts )); then return 1; fi
    echo "Command failed; retrying (${attempt}/${max_attempts}): $*" >&2
    sleep 15
    ((attempt += 1))
  done
}

for command_name in zig nu xcodebuild codesign hdiutil xcrun lipo ditto readlink git tar shasum spctl; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done
command -v "${CREATE_DMG}" >/dev/null || {
  echo "create-dmg is unavailable; install it or set CREATE_DMG to its executable." >&2
  exit 1
}

[[ -z "$(git -C "${SOURCE_ROOT}" status --porcelain --untracked-files=all)" ]] || {
  echo "Release checkout must be clean, including untracked files." >&2
  exit 1
}
[[ "$(git -C "${SOURCE_ROOT}" rev-parse "${RELEASE_TAG}^{commit}" 2>/dev/null)" == \
   "$(git -C "${SOURCE_ROOT}" rev-parse HEAD)" ]] || {
  echo "${RELEASE_TAG} must exist and point at HEAD." >&2
  exit 1
}
grep -Eq "^## ${RELEASE_VERSION//./\\.}([[:space:]]|$)" "${SOURCE_ROOT}/CHANGELOG.md" || {
  echo "CHANGELOG.md has no ${RELEASE_VERSION} release section." >&2
  exit 1
}

# Prefer App Store Connect API credentials in CI; otherwise use a local
# notarytool keychain profile.
NOTARY_AUTH_ARGS=()
if [[ -n "${NOTARY_KEY_FILE:-}" ]]; then
  [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || {
    echo "NOTARY_KEY_FILE requires NOTARY_KEY_ID and NOTARY_ISSUER_ID." >&2
    exit 1
  }
  NOTARY_AUTH_ARGS=(--key "${NOTARY_KEY_FILE}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER_ID}")
else
  if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    for candidate in ghosttal-notary notarytool; do
      if xcrun notarytool history --keychain-profile "${candidate}" >/dev/null 2>&1; then
        NOTARY_PROFILE="${candidate}"
        break
      fi
    done
  fi
  [[ -n "${NOTARY_PROFILE:-}" ]] || {
    echo "No notary credential profile found (tried ghosttal-notary and notarytool)." >&2
    exit 1
  }
  NOTARY_AUTH_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
fi

if [[ -z "${SPARKLE_BIN:-}" ]]; then
  SPARKLE_BIN="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -type d -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)"
fi
[[ -n "${SPARKLE_BIN}" && -x "${SPARKLE_BIN}/sign_update" ]] || {
  echo "Sparkle tools not found; set SPARKLE_BIN to the Sparkle bin directory." >&2
  exit 1
}
readonly SPARKLE_BIN

for setting in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
  grep -Fq "${setting} = ${RELEASE_VERSION};" "${SOURCE_ROOT}/macos/Ghostty.xcodeproj/project.pbxproj" || {
    echo "${setting} does not include RELEASE_VERSION=${RELEASE_VERSION}" >&2
    exit 1
  }
done
security find-identity -v -p codesigning | grep -Fq "${SIGNING_IDENTITY}" || {
  echo "Signing identity is unavailable: ${SIGNING_IDENTITY}" >&2
  exit 1
}

mkdir -p "${STAGE_ROOT}" "${OUTPUT_DIR}"
git -C "${SOURCE_ROOT}" archive --format=tar HEAD | tar -xf - -C "${STAGE_ROOT}"
cd "${STAGE_ROOT}"

zig build -Demit-macos-app=false -Doptimize=ReleaseFast
./macos/build.nu --scheme Ghostty --configuration Release --action build

[[ -d "${APP_PATH}" ]] || { echo "Release app was not produced at ${APP_PATH}" >&2; exit 1; }
readonly BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
readonly BUILT_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist")"
[[ "${BUILT_VERSION}" == "${RELEASE_VERSION}" && "${BUILT_NUMBER}" == "${RELEASE_VERSION}" ]] || {
  echo "Built app version ${BUILT_VERSION} (${BUILT_NUMBER}) does not match ${RELEASE_VERSION}." >&2
  exit 1
}
readonly APP_ARCHS="$(lipo -archs "${APP_PATH}/Contents/MacOS/ghosttal")"
[[ " ${APP_ARCHS} " == *" arm64 "* && " ${APP_ARCHS} " == *" x86_64 "* ]] || {
  echo "Expected a universal app; found architectures: ${APP_ARCHS}" >&2
  exit 1
}

# Sign Sparkle helpers and other nested code from the inside out, then the app.
readonly SPARKLE_FRAMEWORK="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
NESTED_CODE=(
  "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
  "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Installer.xpc"
  "${SPARKLE_FRAMEWORK}/Versions/B/Autoupdate"
  "${SPARKLE_FRAMEWORK}/Versions/B/Updater.app"
  "${SPARKLE_FRAMEWORK}"
  "${APP_PATH}/Contents/PlugIns/DockTilePlugin.plugin"
)
for code_path in "${NESTED_CODE[@]}"; do
  [[ -e "${code_path}" ]] || { echo "Expected nested code is missing: ${code_path}" >&2; exit 1; }
  retry 6 codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${code_path}"
done
retry 6 codesign --force --options runtime --timestamp \
  --entitlements "${STAGE_ROOT}/macos/Ghostty.entitlements" \
  --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

mkdir -p "${DMG_SOURCE}" "${DMG_MOUNT}"
ditto --rsrc --extattr "${APP_PATH}" "${DMG_SOURCE}/Ghosttal.app"
"${CREATE_DMG}" \
  --volname Ghosttal \
  --background "${STAGE_ROOT}/images/ghosttal/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 440 \
  --icon-size 112 \
  --icon Ghosttal.app 165 278 \
  --hide-extension Ghosttal.app \
  --app-drop-link 495 278 \
  --no-internet-enable \
  "${STAGED_DMG}" "${DMG_SOURCE}"

hdiutil attach -readonly -nobrowse -mountpoint "${DMG_MOUNT}" "${STAGED_DMG}"
[[ -d "${DMG_MOUNT}/Ghosttal.app" ]] || { echo "DMG is missing Ghosttal.app" >&2; exit 1; }
[[ -L "${DMG_MOUNT}/Applications" && "$(readlink "${DMG_MOUNT}/Applications")" == /Applications ]] || {
  echo "DMG is missing the /Applications shortcut" >&2
  exit 1
}
hdiutil detach "${DMG_MOUNT}"

retry 6 codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${STAGED_DMG}"
codesign --verify --verbose=2 "${STAGED_DMG}"
xcrun notarytool submit "${STAGED_DMG}" "${NOTARY_AUTH_ARGS[@]}" --wait
retry 6 xcrun stapler staple "${STAGED_DMG}"
xcrun stapler validate "${STAGED_DMG}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${STAGED_DMG}"
ditto --rsrc --extattr "${STAGED_DMG}" "${OUTPUT_DIR}/${DMG_NAME}"

if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  ED_ATTRIBUTES="$("${SPARKLE_BIN}/sign_update" --ed-key-file "${SPARKLE_KEY_FILE}" "${OUTPUT_DIR}/${DMG_NAME}")"
else
  ED_ATTRIBUTES="$("${SPARKLE_BIN}/sign_update" "${OUTPUT_DIR}/${DMG_NAME}")"
fi
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

(cd "${OUTPUT_DIR}" && shasum -a 256 "${DMG_NAME}" > SHA256SUMS)
echo "Release ready: ${OUTPUT_DIR}/${DMG_NAME}"
echo "Architectures: ${APP_ARCHS}"
echo "Checksum: ${OUTPUT_DIR}/SHA256SUMS"
echo "Appcast updated: ${APPCAST_PATH}"
