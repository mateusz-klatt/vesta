#!/bin/bash
# Capture App Store screenshots from the iOS simulator.
#
# Secrets are read from the environment — nothing sensitive is committed:
#   HESTIA_URL   backend origin (e.g. https://hestia.example)
#   OP_USER      operator username (controls are interactive, not greyed)
#   OP_PASS      operator password
#
# The app reads DEBUG launch args (-vesta.url/-vesta.user/-vesta.pass) to skip
# onboarding for deterministic shots. Pass a locale to render a given language
# (RTL is applied automatically by iOS for ar/he/fa).
#
# Usage:
#   SIM=<udid> HESTIA_URL=... OP_USER=... OP_PASS=... scripts/shots.sh home en
#   scripts/shots.sh home ar        # Arabic, right-to-left
set -euo pipefail

SIM="${SIM:-539DEE7E-299A-4BFD-9EE0-7DC6343C58D4}"   # iPhone 17 Pro Max (6.9")
BID="ie.klatt.vesta"
OUT="${OUT:-build/shots}"
WAIT="${WAIT:-7}"
mkdir -p "$OUT"

screen="${1:-home}"
lang="${2:-en}"

args=(-AppleLanguages "($lang)" -AppleLocale "$lang")
case "$screen" in
  connect)  ;;  # no backend override → onboarding/Connect screen
  *)        args+=(-vesta.url "$HESTIA_URL" -vesta.user "$OP_USER" -vesta.pass "$OP_PASS") ;;
esac

xcrun simctl terminate "$SIM" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$SIM" "$BID" "${args[@]}" >/dev/null
/bin/sleep "$WAIT"
xcrun simctl io "$SIM" screenshot "$OUT/${screen}-${lang}.png"
echo "shot: $OUT/${screen}-${lang}.png"
