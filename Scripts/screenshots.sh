#!/usr/bin/env bash
# Captures the App Store screenshot set on the simulators whose pixel sizes App Store Connect requires:
#   iPhone 6.9" (iPhone 17 Pro Max)   1320 × 2868
#   iPad 13"    (iPad Pro 13-inch)    2064 × 2752
#
# Output: fastlane/screenshots/<locale>/<iphone|ipad>-<nn>-<name>.png, which is what
# `fastlane release` uploads. deliver picks the device family from the pixel size, so every locale
# is one flat folder.
#
#   Scripts/screenshots.sh                         # both devices, both locales
#   Scripts/screenshots.sh "iPhone 17 Pro Max"     # one device
#   LOCALES=sv Scripts/screenshots.sh              # one locale
#   TRAIN=560 Scripts/screenshots.sh               # pin the train instead of picking one live
#   SKIP_BUILD=1 Scripts/screenshots.sh            # reuse the last build
#
# Needs TRV_API_KEY in .env.local and `idb` (https://fbidb.io): the iPhone captures drag the bottom
# card to the height that frames each subject, and the iPad ones open the sidebar. Which screen is showing is decided by the
# debug launch arguments -save/-train/-station, so no UI automation has to find its way there.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d /Applications/Xcode.app ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [ -f .env.local ]; then
  # shellcheck disable=SC1091
  set -a; source .env.local; set +a
fi
: "${TRV_API_KEY:?TRV_API_KEY is not set — put it in .env.local}"

BUNDLE_ID="${APP_BUNDLE_ID:-se.tagradar.app}"
DERIVED=".build/DerivedData"
OUT_ROOT="fastlane/screenshots"
IDB="${IDB:-$HOME/.local/bin/idb}"
# Seconds to let the map, the live stream and the timetable settle before each capture.
SETTLE="${SETTLE:-12}"
# Station shown on the departure board. Stockholm C is the busiest board in the country.
STATION="${STATION:-Cst}"

DEVICES=("$@")
if [ $# -eq 0 ]; then
  DEVICES=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")
fi
read -r -a LOCALE_LIST <<<"${LOCALES:-en-US sv}"

# The train to feature. Pinning TRAIN makes a rerun reproducible; otherwise pick one that is
# actually moving right now, so the map has a live position and a drawn route to show.
pick_train() {
  # The key comes through the environment, not argv, so it never shows up in `ps`.
  python3 - <<'PY'
import datetime, json, os, sys, urllib.request
from zoneinfo import ZoneInfo

KEY = os.environ["TRV_API_KEY"]
ENDPOINT = "https://api.trafikinfo.trafikverket.se/v2/data.json"
# A run's departure day is Swedish civil time, the same as TrainKey — so a capture from another
# timezone, or from Sweden just after midnight, does not ask for the wrong day.
TODAY = datetime.datetime.now(ZoneInfo("Europe/Stockholm")).date().isoformat()


def query(body: str):
    request = urllib.request.Request(
        ENDPOINT,
        data=f'<REQUEST><LOGIN authenticationkey="{KEY}"/>{body}</REQUEST>'.encode(),
        headers={"Content-Type": "text/xml"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)["RESPONSE"]["RESULT"][0]


# Trains reporting an active position in the last ten minutes and moving at line speed: those are
# under way, not stabled, so the map has something to draw. Status.Active matters because the map
# hides inactive positions unless the user turns them on (TrainMapView), so an inactive pick would
# give us the empty map this is here to avoid.
moving = query(
    '<QUERY objecttype="TrainPosition" namespace="järnväg.trafikinfo" schemaversion="1.1" limit="500">'
    '<FILTER><AND><GT name="TimeStamp" value="$dateadd(-0.00:10:00)"/>'
    '<GT name="Speed" value="80"/><EQ name="Status.Active" value="true"/></AND></FILTER>'
    "<INCLUDE>Train.AdvertisedTrainNumber</INCLUDE><INCLUDE>Position.WGS84</INCLUDE>"
    "<INCLUDE>Train.OperationalTrainDepartureDate</INCLUDE></QUERY>"
).get("TrainPosition", [])


def out_in_the_country(position: dict) -> bool:
    """Far enough from the three big commuter areas for the train to be the subject of the shot.

    Zoomed to a train inside one, the map is forty overlapping markers and the drawn route
    disappears underneath them."""
    wkt = (position.get("Position") or {}).get("WGS84") or ""
    try:
        lon, lat = (float(n) for n in wkt.removeprefix("POINT (").removesuffix(")").split())
    except ValueError:
        return False
    metros = ((59.33, 18.06), (57.71, 11.97), (55.60, 13.00))  # Stockholm, Göteborg, Malmö
    return all(abs(lat - mlat) > 0.45 or abs(lon - mlon) > 0.45 for mlat, mlon in metros)


def departure_day(position: dict) -> str:
    """The run's own departure day, which is not always the calendar day it is moving on.

    A night train still going at 01:00 belongs to yesterday, and `LiveTrain.key` identifies it by
    that day — so a bare number handed to `-train` would resolve to today and miss it."""
    raw = (position.get("Train") or {}).get("OperationalTrainDepartureDate") or ""
    return raw[:10]


# A candidate is a run — an advertised number together with the day it departed — never a bare
# number: around midnight the same number can be moving on two days at once, and keeping only one
# of them would describe a different run than the position that was actually picked.
candidates: set[tuple[str, str]] = set()
for position in moving:
    ident = (position.get("Train") or {}).get("AdvertisedTrainNumber")
    day = departure_day(position)
    if ident and day and out_in_the_country(position):
        candidates.add((ident, day))
if not candidates:
    sys.exit("no train is out on the line right now — pass TRAIN=<number>")

# Every announcement for those runs, one departure day at a time — just after midnight the trains
# still moving are the overnight runs that departed yesterday, and a query about today would return
# nothing for them.
stations: dict[tuple[str, str], set[str]] = {}
# Cancellation flags in calling order, which is why the query is ordered: what the Saved row shows
# depends on which stops are cancelled, not just how many.
flags: dict[tuple[str, str], list[bool]] = {}
for day in sorted({d for _, d in candidates}):
    idents = sorted(ident for ident, d in candidates if d == day)
    stops = query(
        '<QUERY objecttype="TrainAnnouncement" namespace="rail.trafficinfo" schemaversion="2.0"'
        ' limit="10000" orderby="AdvertisedTimeAtLocation">'
        "<FILTER><AND>"
        f'<IN name="AdvertisedTrainIdent" value="{",".join(idents)}"/>'
        f'<GTE name="ScheduledDepartureDateTime" value="{day}T00:00:00"/>'
        f'<LT name="ScheduledDepartureDateTime" value="{day}T23:59:59"/>'
        # Advertised rows only, because those are the ones `TrainJourney.buildStops` turns into
        # stops. A passing point carries times but is no station, and letting one be the first or
        # last row here would answer the cancellation question about the wrong place.
        '<EQ name="Advertised" value="true"/>'
        "</AND></FILTER>"
        "<INCLUDE>AdvertisedTrainIdent</INCLUDE><INCLUDE>LocationSignature</INCLUDE>"
        "<INCLUDE>Canceled</INCLUDE></QUERY>"
    ).get("TrainAnnouncement", [])
    for row in stops:
        run = (row["AdvertisedTrainIdent"], day)
        stations.setdefault(run, set()).add(row["LocationSignature"])
        flags.setdefault(run, []).append(bool(row.get("Canceled")))


def shows_as_canceled(run: tuple[str, str]) -> bool:
    """Whether the Saved row would carry the red badge.

    `TrainSnapshot.apply` sets `.canceled` when the first or the last stop is cancelled, or when
    every one is — so a run with a cancelled stop in the middle still presents normally and is no
    reason to pass it over, while one cancelled at either end is."""
    rows = flags[run]
    return rows[0] or rows[-1] or all(rows)


# A cancelled run is honest data but a poor advertisement: it puts a red badge on the first thing
# anyone sees on the store page. Rank by how many stations a run calls at — a long-distance one
# fills the timeline and the map — and only fall back to a cancelled candidate if every one of them
# is cancelled.
ranked = sorted(stations, key=lambda run: -len(stations[run]))
running = [run for run in ranked if not shows_as_canceled(run)]
ranked = running or ranked
if not ranked:
    sys.exit("none of the moving trains is advertised on its departure day — pass TRAIN=<number>")

# Emitted as full `<number>@<day>` keys: `-train` and `-save` both parse them, and a bare number
# would be resolved as today's run. The runner-up rides along in the Saved list, so that section
# shows two rows rather than one.
print(" ".join(f"{ident}@{day}" for ident, day in ranked[:2]))
PY
}

if [ -n "${TRAIN:-}" ]; then
  SAVED="${SAVED:-$TRAIN}"
else
  echo "▶ Picking a train that is under way…"
  # Assigned first: inside a here-string the picker's exit status would be lost and the run would
  # go on to capture an empty map with an empty train number.
  PICKED=$(pick_train) || { echo "Could not pick a train — pass TRAIN=<number>"; exit 1; }
  read -r TRAIN SECOND <<<"$PICKED"
  SAVED="${SAVED:-$TRAIN,$SECOND}"
fi
echo "▶ Featuring train $TRAIN; saved list: $SAVED"

if [ -z "${SKIP_BUILD:-}" ]; then
  [ -d Tagradar.xcodeproj ] || Scripts/bootstrap.sh
  echo "▶ Building"
  xcodebuild -project Tagradar.xcodeproj -scheme Tagradar -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" build -quiet
fi
APP=$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "Tagradar.app" | head -1)
[ -n "$APP" ] || { echo "No build in $DERIVED — run without SKIP_BUILD"; exit 1; }

udid_for() {
  xcrun simctl list devices available -j | python3 -c "
import json,sys
for runtime, devices in json.load(sys.stdin)['devices'].items():
    if 'iOS' not in runtime: continue
    for device in devices:
        if device['name'] == sys.argv[1]: print(device['udid']); sys.exit(0)
sys.exit(1)" "$1"
}

for DEVICE in "${DEVICES[@]}"; do
  case "$DEVICE" in iPad*) PREFIX="ipad";; *) PREFIX="iphone";; esac
  UDID=$(udid_for "$DEVICE") || { echo "No simulator named '$DEVICE'"; exit 1; }

  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  # Fresh install, so the Saved list holds exactly what -save pins and nothing from a previous run.
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP"
  # No permission alert in the middle of a capture.
  xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" >/dev/null 2>&1 || true
  # The map opens around the user, so put them at Stockholm C rather than the simulator's default.
  xcrun simctl location "$UDID" set 59.3303,18.0584 >/dev/null 2>&1 || true
  # The status bar Apple uses in its own screenshots.
  xcrun simctl status_bar "$UDID" override \
    --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
  [ -x "$IDB" ] || { echo "idb not found at $IDB — install it or set IDB=<path>"; exit 1; }
  "$IDB" connect "$UDID" >/dev/null 2>&1 || true

  for LOCALE in "${LOCALE_LIST[@]}"; do
    case "$LOCALE" in
      sv) LANGUAGE="sv"; REGION="sv_SE";;
      *)  LANGUAGE="en"; REGION="en_US";;
    esac
    OUT="$OUT_ROOT/$LOCALE"
    mkdir -p "$OUT"
    # This device's previous captures, so a renamed or dropped shot can't linger and be stripped,
    # listed and uploaded alongside the new ones. Other device families and locales are untouched,
    # which is what makes a partial rerun safe.
    rm -f "$OUT/$PREFIX"-*.png
    echo "▶ $DEVICE · $LOCALE → $OUT/$PREFIX-*.png"

    # Language is passed per launch rather than written to the simulator's global preferences, which
    # would need a reboot between locales.
    launch() {
      SIMCTL_CHILD_TRV_API_KEY="$TRV_API_KEY" xcrun simctl launch --terminate-running-process \
        "$UDID" "$BUNDLE_ID" -AppleLanguages "($LANGUAGE)" -AppleLocale "$REGION" "$@" >/dev/null
    }
    settle() {
      python3 -c "import time; time.sleep(${1:-$SETTLE})"
    }
    shot() {
      settle "${2:-$SETTLE}"
      xcrun simctl io "$UDID" screenshot "$OUT/$PREFIX-$1.png" >/dev/null 2>&1
      echo "  ✓ $PREFIX-$1"
    }
    # Drags on the card, in points on a 440 × 956 screen. The detent cannot be set from the outside —
    # `presentationDetents(selection:)` snaps back to the middle height whenever the card's content
    # changes — so these are the same gestures a hand would make.
    swipe() {
      "$IDB" ui swipe --udid "$UDID" --duration 0.4 "$@" >/dev/null 2>&1
      settle 2
    }
    expand_card() { swipe 220 470 220 90; }
    collapse_card() { swipe 220 450 220 930; }
    scroll_card() { swipe 220 780 220 300; }
    # The iPad sidebar is hidden in portrait; its glass toggle sits in the map's top-left corner.
    # Not idempotent: in landscape the sidebar is already open and this would close it, hence the
    # portrait check below.
    open_sidebar() {
      "$IDB" ui tap --udid "$UDID" 40 52 >/dev/null 2>&1
      settle 3
    }
    # App Store screenshots are portrait, and the simulator cannot be rotated from here, so a
    # device left in landscape would silently produce a set with the wrong pixel size — and with
    # the card drags and the sidebar tap, which are both in portrait coordinates, landing
    # somewhere else entirely. Say so instead.
    require_portrait() {
      local dir probe width height
      # A directory, because `sips` needs the .png suffix and macOS `mktemp` cannot add one:
      # appending it to the name would leave the file `mktemp` actually created behind.
      dir=$(mktemp -d -t tagradar-pose)
      probe="$dir/probe.png"
      xcrun simctl io "$UDID" screenshot "$probe" >/dev/null 2>&1
      read -r width height <<<"$(sips -g pixelWidth -g pixelHeight "$probe" | awk '/pixelWidth|pixelHeight/ {printf "%s ", $2}')"
      rm -rf "$dir"
      if [ "${width:-0}" -gt "${height:-1}" ]; then
        echo "$DEVICE is in landscape (${width}x${height}). Rotate it to portrait (Cmd+Left) and rerun." >&2
        exit 1
      fi
    }

    require_portrait
    if [ "$PREFIX" = iphone ]; then
      # The card opens at its middle height over the map. Each shot drags it to whatever frames its
      # subject: up for a list, down to the search bar when the map itself is the subject.
      launch -save "$SAVED"
      shot "01-map"
      launch -train "$TRAIN"
      shot "02-train"
      launch -train "$TRAIN"
      settle
      expand_card
      scroll_card
      shot "03-stops" 2
      launch -station "$STATION"
      settle
      expand_card
      shot "04-station" 2
      launch -train "$TRAIN"
      settle
      collapse_card
      shot "05-route" 2
    else
      # Portrait: the map alone, then a train inspector beside it, then the same two subjects
      # again with the sidebar open, so the set shows both the map at full width and all three
      # columns at once.
      launch
      shot "01-map"
      launch -train "$TRAIN" -save "$SAVED"
      shot "02-train"
      launch -station "$STATION" -save "$SAVED"
      settle
      open_sidebar
      shot "03-station" 2
      launch -train "$TRAIN" -save "$SAVED"
      settle
      open_sidebar
      shot "04-saved" 2
    fi
  done

  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
done

# App Store Connect rejects an alpha channel; the simulator always writes one.
FILES=()
for LOCALE in "${LOCALE_LIST[@]}"; do
  while IFS= read -r file; do FILES+=("$file"); done < <(find "$OUT_ROOT/$LOCALE" -name '*.png' | sort)
done
swift Scripts/strip-alpha.swift "${FILES[@]}"

printf '\n'
for file in "${FILES[@]}"; do
  read -r width height alpha <<<"$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file" | awk '/pixelWidth|pixelHeight|hasAlpha/ {print $2}' | tr '\n' ' ')"
  printf '  %-44s %sx%s alpha=%s\n' "$file" "$width" "$height" "$alpha"
done
echo "Done. Review the images; \`fastlane release\` uploads them with the next release."
