#!/bin/zsh

set -euo pipefail

CAMENYA_REPO_ROOT=${0:A:h:h}
CAMENYA_CONFIG_PATH=${CAMENYA_LOCAL_CONFIG:-"$CAMENYA_REPO_ROOT/.camenya/local-signing.plist"}

read_local_setting() {
  local key=$1
  plutil -extract "$key" raw -o - "$CAMENYA_CONFIG_PATH" 2>/dev/null || true
}

if [[ -f "$CAMENYA_CONFIG_PATH" ]]; then
  if [[ -L "$CAMENYA_CONFIG_PATH" ]]; then
    print -u2 "Refusing to read local signing configuration through a symbolic link."
    exit 1
  fi

  if [[ "$CAMENYA_CONFIG_PATH" == "$CAMENYA_REPO_ROOT"/* ]] &&
     ! git -C "$CAMENYA_REPO_ROOT" check-ignore -q "$CAMENYA_CONFIG_PATH"; then
    print -u2 "Refusing to read signing data from a repository path that Git does not ignore."
    exit 1
  fi

  CAMENYA_CONFIG_MODE=$(stat -f '%Lp' "$CAMENYA_CONFIG_PATH")
  if (( (8#$CAMENYA_CONFIG_MODE & 8#077) != 0 )); then
    print -u2 "Local signing configuration is readable by another user. Run chmod 600 on it and retry."
    exit 1
  fi

  CAMENYA_TEAM_ID=${CAMENYA_TEAM_ID:-$(read_local_setting TeamID)}
  CAMENYA_DEVICE_ID=${CAMENYA_DEVICE_ID:-$(read_local_setting DeviceID)}
  CAMENYA_BUNDLE_ID=${CAMENYA_BUNDLE_ID:-$(read_local_setting BundleID)}
fi

if [[ -z ${CAMENYA_DEVICE_ID:-} || -z ${CAMENYA_TEAM_ID:-} || -z ${CAMENYA_BUNDLE_ID:-} ]]; then
  print -u2 "Local signing is not configured. Run Scripts/configure-local-signing.sh first."
  exit 1
fi

if [[ ! "$CAMENYA_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]]; then
  print -u2 "The configured Team ID is invalid. Run Scripts/configure-local-signing.sh again."
  exit 1
fi

if [[ ! "$CAMENYA_DEVICE_ID" =~ '^[A-Za-z0-9-]+$' ]]; then
  print -u2 "The configured device destination ID is invalid. Run Scripts/configure-local-signing.sh again."
  exit 1
fi

if [[ ! "$CAMENYA_BUNDLE_ID" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' ]] ||
   [[ "$CAMENYA_BUNDLE_ID" != *.* ]]; then
  print -u2 "The configured bundle identifier is invalid. Run Scripts/configure-local-signing.sh again."
  exit 1
fi

CAMENYA_DERIVED_DATA=${CAMENYA_DERIVED_DATA:-/private/tmp/camenya-device}
CAMENYA_APP_PATH="$CAMENYA_DERIVED_DATA/Build/Products/Debug-iphoneos/Camenya.app"

cd "$CAMENYA_REPO_ROOT"

CAMENYA_DESTINATIONS=$(xcodebuild \
  -project Camenya.xcodeproj \
  -scheme Camenya \
  -showdestinations 2>&1)

if [[ "$CAMENYA_DESTINATIONS" != *"$CAMENYA_DEVICE_ID"* ]]; then
  print -u2 "The configured iPhone is not available to Xcode. Connect and unlock it, then rerun this script."
  exit 1
fi

xcodebuild -quiet \
  -project Camenya.xcodeproj \
  -scheme Camenya \
  -configuration Debug \
  -destination "id=$CAMENYA_DEVICE_ID" \
  -derivedDataPath "$CAMENYA_DERIVED_DATA" \
  DEVELOPMENT_TEAM="$CAMENYA_TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$CAMENYA_BUNDLE_ID" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

xcrun devicectl device install app \
  --device "$CAMENYA_DEVICE_ID" \
  "$CAMENYA_APP_PATH"

if ! CAMENYA_LAUNCH_OUTPUT=$(xcrun devicectl device process launch \
  --device "$CAMENYA_DEVICE_ID" \
  --terminate-existing \
  "$CAMENYA_BUNDLE_ID" 2>&1); then
  print -u2 "$CAMENYA_LAUNCH_OUTPUT"
  if [[ "$CAMENYA_LAUNCH_OUTPUT" == *"Locked"* ]]; then
    print "Camenya was installed successfully. Unlock the iPhone and open the app manually."
    exit 0
  fi
  exit 1
fi

print "$CAMENYA_LAUNCH_OUTPUT"
print "Camenya installed and launched on the configured iPhone."
