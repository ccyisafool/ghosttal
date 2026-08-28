#!/usr/bin/env bash
#
# Upload the six release secrets to the GitHub repository so the
# release-ghosttal.yml workflow can sign, notarize, and publish.
#
# Run this ON A MAC THAT ALREADY RELEASES (it reads the Developer ID
# certificate and Sparkle key from the login keychain). Secrets go straight
# from this machine into GitHub's encrypted secret store via `gh`; nothing
# is printed and all temporary files are removed.
#
# Prerequisites:
#   - `gh auth login` completed with access to the repository
#   - An App Store Connect API key (.p8 downloaded from
#     appstoreconnect.apple.com → Users and Access → Integrations)

set -euo pipefail

readonly REPO="${REPO:-ccyisafool/ghosttal}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Chenyang Cheng (Y63C8FW5ZK)}"
readonly WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf -- "${WORK_DIR}"; }
trap cleanup EXIT

for command_name in gh security base64; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done
gh auth status >/dev/null || exit 1

echo "Uploading secrets to ${REPO}."
echo

## 1. Developer ID certificate ------------------------------------------------
# `security export` cannot export a single identity (it would export every
# private key in the keychain), so this one step goes through Keychain Access.
echo "== 1/3: Developer ID certificate =="
echo "In Keychain Access (login keychain → My Certificates):"
echo "  1. Right-click '${SIGNING_IDENTITY}'"
echo "  2. Export → file format 'Personal Information Exchange (.p12)'"
echo "  3. Save it anywhere temporary and protect it with a password"
read -r -p "Path to the exported .p12 file: " CERT_PATH
CERT_PATH="${CERT_PATH/#\~/${HOME}}"
[[ -f "${CERT_PATH}" ]] || { echo "No such file: ${CERT_PATH}" >&2; exit 1; }
read -r -s -p "Password you protected the export with: " CERT_PASSWORD
echo
[[ -n "${CERT_PASSWORD}" ]] || { echo "Password must not be empty." >&2; exit 1; }

base64 -i "${CERT_PATH}" | gh secret set MACOS_CERTIFICATE_P12 -R "${REPO}"
printf '%s' "${CERT_PASSWORD}" | gh secret set MACOS_CERTIFICATE_PASSWORD -R "${REPO}"
unset CERT_PASSWORD
rm -f -- "${CERT_PATH}"
echo "Certificate uploaded; the local .p12 file has been deleted."
echo

## 2. Sparkle EdDSA private key -----------------------------------------------
echo "== 2/3: Sparkle update-signing key =="
SPARKLE_BIN="${SPARKLE_BIN:-$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
  -type d -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)}"
[[ -n "${SPARKLE_BIN}" && -x "${SPARKLE_BIN}/generate_keys" ]] || {
  echo "Sparkle tools not found; set SPARKLE_BIN to the Sparkle bin directory." >&2
  exit 1
}
"${SPARKLE_BIN}/generate_keys" -x "${WORK_DIR}/sparkle-key"
gh secret set SPARKLE_PRIVATE_KEY -R "${REPO}" < "${WORK_DIR}/sparkle-key"
echo "Sparkle key uploaded."
echo

## 3. App Store Connect API key -----------------------------------------------
echo "== 3/3: App Store Connect API key =="
echo "Create one at appstoreconnect.apple.com → Users and Access → Integrations"
echo "(role: Developer is sufficient), download the AuthKey_XXXXXXXXXX.p8 file,"
echo "and note the Key ID and Issuer ID shown on that page."
read -r -p "Path to the downloaded .p8 file: " ASC_KEY_PATH
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/${HOME}}"
[[ -f "${ASC_KEY_PATH}" ]] || { echo "No such file: ${ASC_KEY_PATH}" >&2; exit 1; }
read -r -p "Key ID: " ASC_KEY_ID
read -r -p "Issuer ID: " ASC_ISSUER_ID
[[ -n "${ASC_KEY_ID}" && -n "${ASC_ISSUER_ID}" ]] || {
  echo "Key ID and Issuer ID must not be empty." >&2
  exit 1
}

gh secret set ASC_API_KEY_P8 -R "${REPO}" < "${ASC_KEY_PATH}"
printf '%s' "${ASC_KEY_ID}" | gh secret set ASC_API_KEY_ID -R "${REPO}"
printf '%s' "${ASC_ISSUER_ID}" | gh secret set ASC_API_ISSUER_ID -R "${REPO}"
echo "Notary API key uploaded."
echo

echo "All six secrets are set:"
gh secret list -R "${REPO}"
echo
echo "Consider deleting the downloaded .p8 file (Apple lets you re-download it"
echo "only once) after saving a copy in your password manager:"
echo "  ${ASC_KEY_PATH}"
