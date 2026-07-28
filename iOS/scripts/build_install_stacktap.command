#!/bin/zsh

set -euo pipefail

ROOT="$HOME/AudioRepeaterIOSWork/iOS"
UDID="YOUR_DEVICE_UDID"
RUN_ID="stacktap-$(date +%Y%m%d-%H%M%S)"
DERIVED="$ROOT/build/DeviceDerivedData-Xcode27-i12m-$RUN_ID"
STATUS="$ROOT/build/stacktap-gui-latest.status"
LOG="$ROOT/build/stacktap-gui-latest.log"
APP_PATH_FILE="$ROOT/build/stacktap-gui-latest-app.txt"

mkdir -p "$ROOT/build"
: > "$LOG"
: > "$STATUS"
exec > >(tee -a "$LOG") 2>&1

function finish {
    local code=$?
    print -r -- "$code" > "$STATUS"
}
trap finish EXIT

cd "$ROOT"
export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"

xcodebuild \
  -project AudioRepeaterIOS.xcodeproj \
  -scheme AudioRepeaterIOS \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

APP="$DERIVED/Build/Products/Debug-iphoneos/AudioRepeaterIOS.app"
codesign --verify --deep --strict --verbose=2 "$APP"
security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | \
  plutil -extract ExpirationDate raw -o - -
security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | \
  plutil -extract ProvisionedDevices json -o - -
xcrun devicectl device install app --device "$UDID" "$APP"
print -r -- "$APP" > "$APP_PATH_FILE"
