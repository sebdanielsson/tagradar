#!/usr/bin/env bash
# Build, install and launch Tågradar on an iOS Simulator, optionally taking a screenshot.
#
#   Scripts/simulator.sh                      # iPhone 17 Pro
#   Scripts/simulator.sh "iPad Pro 13-inch (M5)"
#   Scripts/simulator.sh "iPhone Duo"                 # needs the iOS 27.1 runtime
#   RUNTIME=27.0 Scripts/simulator.sh                 # pick the runtime when a name exists on several (default: newest)
#   Scripts/simulator.sh "iPhone 17 Pro" shot.png   # also save a screenshot after launch
#   TRAIN=520 Scripts/simulator.sh                    # open a train's detail at launch, debug builds only
#   STATION=Cst Scripts/simulator.sh                  # open a station's board at launch, debug builds only
#   SAVE=520,537 Scripts/simulator.sh                 # pin trains in Saved at launch, debug builds only
#   SKIP_BUILD=1 Scripts/simulator.sh                 # reuse the last build
#
# If .env.local defines TRV_API_KEY it is passed to the app as an environment variable.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env.local ]; then
  # shellcheck disable=SC1091
  set -a; source .env.local; set +a
fi
DEVICE="${1:-iPhone 17 Pro}"
SHOT="${2:-}"
BUNDLE_ID="${APP_BUNDLE_ID:-se.tagradar.app}"
DERIVED=".build/DerivedData"

if [ -d /Applications/Xcode.app ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

[ -d Tagradar.xcodeproj ] || Scripts/bootstrap.sh

# Runtime keys look like com.apple.CoreSimulator.SimRuntime.iOS-27-1. The same device name exists once per
# installed runtime, so take the newest unless RUNTIME asks for a specific one.
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
data=json.load(sys.stdin)['devices']
want,runtime_wanted=sys.argv[1],sys.argv[2]
matches=[]
for runtime,devs in data.items():
    if '.iOS-' not in runtime: continue
    version=tuple(int(p) for p in runtime.rsplit('.iOS-',1)[1].split('-'))
    if runtime_wanted and version!=tuple(int(p) for p in runtime_wanted.split('.')): continue
    matches+=[(version,d['udid']) for d in devs if d['name']==want]
if not matches: sys.exit(1)
print(max(matches)[1])
" "$DEVICE" "${RUNTIME:-}") || {
  echo "No simulator named '$DEVICE'${RUNTIME:+ on iOS $RUNTIME}. Available:"
  xcrun simctl list devices available | grep -E "^-- iOS|iPhone|iPad"
  exit 1
}

if [ -z "${SKIP_BUILD:-}" ]; then
echo "▶ Building for $DEVICE ($UDID)"
# Keep (ad hoc) code signing on: without it the widget extension loses its entitlements and App Intents
# registration, so widgets stay on their placeholder and the App Group is unavailable.
xcodebuild -project Tagradar.xcodeproj -scheme Tagradar -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  build -quiet
fi

APP=$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "Tagradar.app" | head -1)
xcrun simctl boot "$UDID" 2>/dev/null || true
# Xcode 27 replaced Simulator.app with DeviceHub.app.
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 \
  || open -a "${DEVELOPER_DIR:-$(xcode-select -p)}/../Applications/DeviceHub.app" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
if [ -f .env.local ]; then
  # shellcheck disable=SC1091
  set -a; source .env.local; set +a
fi
ARGS=()
[ -n "${TRAIN:-}" ] && ARGS+=(-train "$TRAIN")
[ -n "${STATION:-}" ] && ARGS+=(-station "$STATION")
[ -n "${SAVE:-}" ] && ARGS+=(-save "$SAVE")
SIMCTL_CHILD_TRV_API_KEY="${TRV_API_KEY:-}" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null
echo "▶ Launched $BUNDLE_ID"

if [ -n "$SHOT" ]; then
  sleep 4
  xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null
  echo "▶ Screenshot saved to $SHOT"
fi
