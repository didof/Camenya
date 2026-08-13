#!/bin/zsh

set -euo pipefail

CAMENYA_REPO_ROOT=${0:A:h:h}
CAMENYA_CONFIG_PATH=${CAMENYA_LOCAL_CONFIG:-"$CAMENYA_REPO_ROOT/.camenya/local-signing.plist"}
CAMENYA_CONFIG_DIR=${CAMENYA_CONFIG_PATH:h}
CAMENYA_INSTALL_AFTER_CONFIGURATION=0
CAMENYA_SHOW_DESTINATIONS=0

print_usage() {
  cat <<'USAGE'
Configure local signing for a self-built copy of Camenya.

Usage:
  Scripts/configure-local-signing.sh [--show-destinations] [--install]

Options:
  --show-destinations  Show the devices currently visible to Xcode.
  --install            Build, sign, install, and launch after saving.
  --help               Show this help.

The configuration is written to .camenya/local-signing.plist, which is
ignored by Git. Existing CAMENYA_TEAM_ID, CAMENYA_DEVICE_ID, and
CAMENYA_BUNDLE_ID environment variables provide non-interactive values.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --install)
      CAMENYA_INSTALL_AFTER_CONFIGURATION=1
      ;;
    --show-destinations)
      CAMENYA_SHOW_DESTINATIONS=1
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      print_usage >&2
      exit 2
      ;;
  esac
  shift
done

cd "$CAMENYA_REPO_ROOT"

if [[ "$CAMENYA_CONFIG_PATH" == "$CAMENYA_REPO_ROOT"/* ]] &&
   ! git check-ignore -q "$CAMENYA_CONFIG_PATH"; then
  print -u2 "Refusing to write local signing data: the configuration path is not ignored by Git."
  exit 1
fi

if [[ -L "$CAMENYA_CONFIG_PATH" ]]; then
  print -u2 "Refusing to replace a symbolic link at the local configuration path."
  exit 1
fi

if (( CAMENYA_SHOW_DESTINATIONS == 1 )) || [[ -z ${CAMENYA_DEVICE_ID:-} ]]; then
  print "Devices visible to Xcode:"
  xcodebuild -project Camenya.xcodeproj -scheme Camenya -showdestinations
  print
fi

CAMENYA_TEAM_VALUE=${CAMENYA_TEAM_ID:-}
CAMENYA_DEVICE_VALUE=${CAMENYA_DEVICE_ID:-}
CAMENYA_BUNDLE_VALUE=${CAMENYA_BUNDLE_ID:-}

if [[ -z "$CAMENYA_TEAM_VALUE" ]]; then
  read "CAMENYA_TEAM_VALUE?Apple Development Team ID (10 letters or digits): "
fi

if [[ -z "$CAMENYA_DEVICE_VALUE" ]]; then
  read "CAMENYA_DEVICE_VALUE?Physical iPhone destination ID: "
fi

if [[ -z "$CAMENYA_BUNDLE_VALUE" ]]; then
  CAMENYA_RANDOM_SUFFIX=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c1-12)
  CAMENYA_SUGGESTED_BUNDLE="org.camenya.local.$CAMENYA_RANDOM_SUFFIX"
  read "CAMENYA_BUNDLE_VALUE?Unique bundle identifier [$CAMENYA_SUGGESTED_BUNDLE]: "
  CAMENYA_BUNDLE_VALUE=${CAMENYA_BUNDLE_VALUE:-$CAMENYA_SUGGESTED_BUNDLE}
fi

if [[ ! "$CAMENYA_TEAM_VALUE" =~ '^[A-Z0-9]{10}$' ]]; then
  print -u2 "The Team ID must contain exactly 10 uppercase letters or digits."
  exit 1
fi

if [[ ! "$CAMENYA_DEVICE_VALUE" =~ '^[A-Za-z0-9-]+$' ]]; then
  print -u2 "The device destination ID contains unsupported characters."
  exit 1
fi

if [[ ! "$CAMENYA_BUNDLE_VALUE" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' ]] ||
   [[ "$CAMENYA_BUNDLE_VALUE" != *.* ]]; then
  print -u2 "The bundle identifier is not valid. Use reverse-DNS form, such as org.example.camenya."
  exit 1
fi

mkdir -p "$CAMENYA_CONFIG_DIR"
if [[ "$CAMENYA_CONFIG_DIR" == "$CAMENYA_REPO_ROOT/.camenya" ]]; then
  chmod 700 "$CAMENYA_CONFIG_DIR"
fi

CAMENYA_TEMP_CONFIG=$(mktemp "$CAMENYA_CONFIG_DIR/.local-signing.XXXXXX")
trap 'rm -f "$CAMENYA_TEMP_CONFIG"' EXIT INT TERM

plutil -create xml1 "$CAMENYA_TEMP_CONFIG"
plutil -insert TeamID -string "$CAMENYA_TEAM_VALUE" "$CAMENYA_TEMP_CONFIG"
plutil -insert DeviceID -string "$CAMENYA_DEVICE_VALUE" "$CAMENYA_TEMP_CONFIG"
plutil -insert BundleID -string "$CAMENYA_BUNDLE_VALUE" "$CAMENYA_TEMP_CONFIG"
chmod 600 "$CAMENYA_TEMP_CONFIG"
mv "$CAMENYA_TEMP_CONFIG" "$CAMENYA_CONFIG_PATH"
trap - EXIT INT TERM

if [[ "$CAMENYA_CONFIG_PATH" == "$CAMENYA_REPO_ROOT"/* ]]; then
  print "Local signing configuration saved. Its values were not printed and Git ignores the file."
else
  print "Local signing configuration saved outside the repository with owner-only permissions. Its values were not printed."
fi

if (( CAMENYA_INSTALL_AFTER_CONFIGURATION == 1 )); then
  exec "$CAMENYA_REPO_ROOT/Scripts/install-debug-app.sh"
fi
