#!/bin/bash

set -euo pipefail

CAMENYA_REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$CAMENYA_REPO_ROOT"

CAMENYA_FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  CAMENYA_FAILURES=$((CAMENYA_FAILURES + 1))
}

require_file() {
  if [[ ! -f "$1" ]]; then
    fail "required public file is missing: $1"
  fi
}

CAMENYA_PATHS=()
while IFS= read -r -d '' path; do
  if [[ -e "$path" ]]; then
    CAMENYA_PATHS+=("$path")
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

for required in README.md GOVERNANCE.md CONTRIBUTING.md DCO LICENSE SECURITY.md SUPPORT.md TRADEMARKS.md \
  Scripts/configure-local-signing.sh Scripts/install-debug-app.sh .github/workflows/quality.yml \
  Camenya.xcodeproj/project.pbxproj; do
  require_file "$required"
done

for path in "${CAMENYA_PATHS[@]}"; do
  case "$path" in
    *.app|*.app/*|*.ipa|*.xcarchive|*.xcarchive/*|*.dSYM|*.dSYM/*|*.xcresult|*.xcresult/*|*.xcactivitylog|\
    *.mobileprovision|*.provisionprofile|*.p12|*.pfx|*.cer|*.der|*.key|*.pem|\
    *.entitlements|*.xcframework|*.xcframework/*|*.framework|*.framework/*|\
    */xcuserdata/*|xcuserdata/*|*/DerivedData/*|DerivedData/*|*/Archives/*|Archives/*|\
    ExportOptions.plist|*/ExportOptions.plist|.camenya/local-signing.plist|.camenya/.local-signing.*)
      fail "forbidden signing, machine-local, or compiled artifact is tracked: $path"
      ;;
    Package.swift|*/Package.swift|Package.resolved|*/Package.resolved|Podfile|*/Podfile|Podfile.lock|*/Podfile.lock|\
    Cartfile|*/Cartfile|Cartfile.resolved|*/Cartfile.resolved|Mintfile|*/Mintfile|*.podspec)
      fail "third-party dependency or vendoring manifest is tracked: $path"
      ;;
  esac

  if [[ -f "$path" ]]; then
    size=$(wc -c < "$path" | tr -d ' ')
    if (( size > 10485760 )); then
      fail "tracked file exceeds 10 MiB and requires explicit maintainer review: $path"
    fi
  fi
done

scan_files() {
  local pattern=$1
  shift
  local match
  match=$(grep -EnI "$pattern" "$@" 2>/dev/null || true)
  if [[ -n "$match" ]]; then
    printf '%s\n' "$match" >&2
    return 0
  fi
  return 1
}

CAMENYA_TEXT_PATHS=()
for path in "${CAMENYA_PATHS[@]}"; do
  # This verifier necessarily contains the forbidden-token patterns themselves.
  if [[ -f "$path" && "$path" != "Scripts/verify-public-repository.sh" ]]; then
    CAMENYA_TEXT_PATHS+=("$path")
  fi
done

if scan_files '(/Users/[^/[:space:]<>$({]+|/home/[^/[:space:]<>$({]+)' "${CAMENYA_TEXT_PATHS[@]}"; then
  fail "an absolute personal home path appears in repository content"
fi

if scan_files '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})' "${CAMENYA_TEXT_PATHS[@]}"; then
  fail "a value shaped like an Apple device or CoreDevice identifier appears in repository content"
fi

if scan_files '(DEVELOPMENT_TEAM|TeamID|TEAM_ID)[[:space:]="'"'"'<>:/-]+[A-Z0-9]{10}([^A-Z0-9]|$)' "${CAMENYA_TEXT_PATHS[@]}"; then
  fail "a literal Apple Development Team identifier appears in repository content"
fi

if scan_files '(com\.didof|CODE_SIGN_ENTITLEMENTS|PROVISIONING_PROFILE|PROVISIONING_PROFILE_SPECIFIER|SystemCapabilities[[:space:]]*=)' "${CAMENYA_TEXT_PATHS[@]}"; then
  fail "a personal bundle namespace, entitlement, profile, or capability setting appears in repository content"
fi

CAMENYA_PROJECT=Camenya.xcodeproj/project.pbxproj
if grep -Eq 'DEVELOPMENT_TEAM[[:space:]]*=' "$CAMENYA_PROJECT"; then
  fail "the Xcode project contains a Development Team"
fi

if [[ $(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = org\.camenya\.app;' "$CAMENYA_PROJECT" | wc -l | tr -d ' ') != 2 ]]; then
  fail "the app target must use the neutral org.camenya.app bundle identifier in Debug and Release"
fi

if [[ $(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = org\.camenya\.app\.tests;' "$CAMENYA_PROJECT" | wc -l | tr -d ' ') != 2 ]]; then
  fail "the test target must use the neutral org.camenya.app.tests bundle identifier in Debug and Release"
fi

CAMENYA_USAGE_KEYS=$(grep -Eo 'INFOPLIST_KEY_NS[A-Za-z]+UsageDescription' "$CAMENYA_PROJECT" | sort -u || true)
CAMENYA_ALLOWED_USAGE_KEYS=$(printf '%s\n' \
  INFOPLIST_KEY_NSCameraUsageDescription \
  INFOPLIST_KEY_NSMicrophoneUsageDescription \
  INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription \
  INFOPLIST_KEY_NSSpeechRecognitionUsageDescription | sort)

if [[ "$CAMENYA_USAGE_KEYS" != "$CAMENYA_ALLOWED_USAGE_KEYS" ]]; then
  fail "the app permission set changed; governance review is required"
fi

CAMENYA_SOURCE_PATHS=()
while IFS= read -r -d '' path; do
  CAMENYA_SOURCE_PATHS+=("$path")
done < <(find Camenya -type f -name '*.swift' -print0)

if scan_files '(URLSession|import[[:space:]]+(Network|WebKit|CloudKit|StoreKit)|Firebase|Analytics|Telemetry|Sentry|PostHog|Mixpanel|Amplitude)' "${CAMENYA_SOURCE_PATHS[@]}"; then
  fail "network, cloud, commerce, analytics, or telemetry code appears in the app target"
fi

if ! git check-ignore -q .camenya/local-signing.plist; then
  fail ".camenya/local-signing.plist is not ignored by Git"
fi

if ! git diff --check; then
  fail "git diff --check reported whitespace errors"
fi

if (( CAMENYA_FAILURES > 0 )); then
  printf '\nPublic repository verification failed with %d issue(s).\n' "$CAMENYA_FAILURES" >&2
  exit 1
fi

printf 'Public repository guardrails passed.\n'
