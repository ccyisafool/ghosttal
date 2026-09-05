#!/usr/bin/env bash

set -euo pipefail

readonly SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_PATH="${SOURCE_ROOT}/macos/Ghostty.xcodeproj"
readonly EXPECTED_VERSION="${1:-}"

[[ "${EXPECTED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: $0 X.Y.Z" >&2
  exit 1
}

for target in Ghostty DockTilePlugin; do
  for configuration in Debug Release ReleaseLocal; do
    settings="$(xcodebuild \
      -project "${PROJECT_PATH}" \
      -target "${target}" \
      -configuration "${configuration}" \
      -disableAutomaticPackageResolution \
      -showBuildSettings)"

    for setting in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
      value="$(awk -F ' = ' -v key="${setting}" \
        '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' <<<"${settings}")"
      [[ "${value}" == "${EXPECTED_VERSION}" ]] || {
        echo "${target} ${configuration} ${setting} is ${value:-unset}; expected ${EXPECTED_VERSION}." >&2
        exit 1
      }
    done
  done
done

echo "All Ghosttal app-target version settings match ${EXPECTED_VERSION}."
