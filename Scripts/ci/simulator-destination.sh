#!/usr/bin/env bash
# Prints an xcodebuild -destination for an iPhone simulator that exists on this machine.
#
# GitHub's macOS runners (first seen on macos-26) sometimes hand out a machine where CoreSimulator
# has not registered its device set yet, and `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
# then fails with "Unable to find a device matching the provided destination specifier" — the same
# image passes on the next run. Waiting for the device set and addressing the simulator by UDID avoids
# that race, and the fallback covers an image that ships a runtime but no devices. The xcode-27 image
# has no iPhone 17 Pro, so there the newest iPhone on the newest runtime is used.
set -euo pipefail

command -v jq >/dev/null || { echo "::error::jq is required by $0." >&2; exit 1; }

# capture/1 emits nothing when the key does not match, so watchOS, tvOS and visionOS runtimes
# drop out of the pipeline rather than erroring.
newest_iphone() {
  xcrun simctl list devices available --json | jq -r '
    [ .devices | to_entries[]
      | (.key | capture("SimRuntime\\.iOS-(?<major>[0-9]+)-(?<minor>[0-9]+)")) as $os
      | .value[]
      | select(.name | startswith("iPhone"))
      | { udid, name, os: [($os.major | tonumber), ($os.minor | tonumber)] } ]
    | sort_by(.os) as $iphones
    | [ $iphones[] | select(.os == ($iphones | last.os)) ] as $newest
    | ((($newest | map(select(.name == "iPhone 17 Pro"))) + $newest | first) // empty).udid'
}

# `|| udid=""` matters: a runner whose CoreSimulator is not up yet can fail the simctl call
# outright, and errexit would then kill the script on the first attempt instead of retrying it.
for attempt in $(seq 1 6); do
  udid=$(newest_iphone) || udid=""
  [ -n "$udid" ] && break
  echo "No iPhone simulator registered yet (attempt $attempt/6); waiting for CoreSimulator…" >&2
  [ "$attempt" -lt 6 ] && sleep 5
done

if [ -z "${udid:-}" ]; then
  echo "Creating a simulator: this image has no iPhone device." >&2
  runtime=$(xcrun simctl list runtimes --json | jq -r '
    [ .runtimes[]
      | select(.isAvailable)
      | (.identifier | capture("SimRuntime\\.iOS-(?<major>[0-9]+)-(?<minor>[0-9]+)")) as $os
      | { identifier, os: [($os.major | tonumber), ($os.minor | tonumber)] } ]
    | sort_by(.os) | (last // empty).identifier') || runtime=""
  devicetype=$(xcrun simctl list devicetypes --json | jq -r '
    [ .devicetypes[] | select(.identifier | test("SimDeviceType\\.iPhone-")) ]
    | (map(select(.identifier | test("iPhone-17-Pro$"))) + .) | first.identifier // empty') || devicetype=""
  if [ -n "$runtime" ] && [ -n "$devicetype" ]; then
    udid=$(xcrun simctl create ci-iphone "$devicetype" "$runtime") || udid=""
  fi
fi

if [ -z "${udid:-}" ]; then
  echo "::error::No iOS simulator is available on this runner." >&2
  xcrun simctl list devices >&2 || true
  exit 1
fi

printf 'platform=iOS Simulator,id=%s\n' "$udid"
