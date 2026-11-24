#!/usr/bin/env bash
# Print the UDID of an iOS Simulator that `xcodebuild` can actually test the
# Vesta scheme on. Some GitHub macOS runner images ship without a usable iOS
# simulator for the selected Xcode (only the "Any iOS Simulator Device"
# placeholder), which fails `make test` with "Unable to find a device matching
# the provided destination specifier". When that happens, create a device on
# the newest installed iOS runtime, and if there is none, download the iOS
# platform first.
#
# Usage (after `make setup`): SIMULATOR_ID=$(scripts/ci-simulator.sh)
set -euo pipefail

PREFERRED="${SIMULATOR:-iPhone 17 Pro}"

eligible() {
    # Concrete iPhone simulators the scheme accepts, as "<os>\t<name>\t<id>".
    xcodebuild -project Vesta.xcodeproj -scheme Vesta -showdestinations 2>/dev/null \
        | sed -nE 's/.*platform:iOS Simulator, (arch:[^,]+, )?id:([0-9A-F-]{36}), OS:([0-9.]+), name:(iPhone[^}]*[^ }]) *\}.*/\3\t\4\t\2/p'
}

pick() {
    # Prefer the named device, then any iPhone; newest OS first.
    local rows
    rows="$(eligible | sort -t $'\t' -k1,1Vr)"
    [ -n "$rows" ] || return 1
    local preferred
    preferred="$(printf '%s\n' "$rows" | awk -F '\t' -v n="$PREFERRED" '$2 == n { print $3; exit }')"
    if [ -n "$preferred" ]; then echo "$preferred"; else printf '%s\n' "$rows" | head -n1 | cut -f3; fi
}

create_device() {
    # Newest available iOS runtime, plus the preferred device type if it supports it.
    local runtime type
    runtime="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"]
       if r.get("platform") == "iOS" and r.get("isAvailable")]
rts.sort(key=lambda r: [int(p) for p in r["version"].split(".")], reverse=True)
print(rts[0]["identifier"] if rts else "")')"
    [ -n "$runtime" ] || return 1
    type="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
want, rid = sys.argv[1], sys.argv[2]
rt = next(r for r in json.load(sys.stdin)["runtimes"] if r["identifier"] == rid)
phones = [t for t in rt.get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
match = [t for t in phones if t["name"] == want]
print((match or phones[-1:] or [{"identifier": ""}])[0]["identifier"])' "$PREFERRED" "$runtime")"
    [ -n "$type" ] || return 1
    echo "No usable iOS simulator; creating one ($type on $runtime)" >&2
    xcrun simctl create "CI iPhone" "$type" "$runtime" >/dev/null
}

if id="$(pick)"; then echo "$id"; exit 0; fi

if create_device && id="$(pick)"; then echo "$id"; exit 0; fi

echo "No iOS simulator runtime for this Xcode; downloading the iOS platform" >&2
xcodebuild -downloadPlatform iOS >&2
if create_device && id="$(pick)"; then echo "$id"; exit 0; fi

echo "Still no usable iOS simulator. Destinations:" >&2
xcodebuild -project Vesta.xcodeproj -scheme Vesta -showdestinations >&2 || true
xcrun simctl list runtimes >&2 || true
exit 1
