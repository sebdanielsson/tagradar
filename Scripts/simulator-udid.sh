#!/usr/bin/env bash
# Prints the UDID of the available iOS simulator with the given name.
#
#   Scripts/simulator-udid.sh "iPhone 17 Pro Max"
#   RUNTIME=27.0 Scripts/simulator-udid.sh "iPhone 17 Pro Max"
#
# The same name exists once per installed runtime, so this takes the newest unless RUNTIME asks for a
# specific one. Exits 1, printing nothing, when there is no match.
set -euo pipefail

# Runtime keys look like com.apple.CoreSimulator.SimRuntime.iOS-27-1.
xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)['devices']
want, runtime_wanted = sys.argv[1], sys.argv[2]
matches = []
for runtime, devices in data.items():
    if '.iOS-' not in runtime:
        continue
    version = tuple(int(part) for part in runtime.rsplit('.iOS-', 1)[1].split('-'))
    if runtime_wanted and version != tuple(int(part) for part in runtime_wanted.split('.')):
        continue
    matches += [(version, device['udid']) for device in devices if device['name'] == want]
if not matches:
    sys.exit(1)
print(max(matches)[1])
" "$1" "${RUNTIME:-}"
