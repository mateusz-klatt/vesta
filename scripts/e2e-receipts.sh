#!/bin/sh
# Live end-to-end check of receipts pairing against a real hestia.
# Asks for the one-time pairing code without echoing it, so it never lands in
# shell history or logs. Usage: scripts/e2e-receipts.sh https://your-hestia
set -eu
SERVER="${1:?usage: scripts/e2e-receipts.sh https://your-hestia}"
printf 'Pairing code from hestia (Budżet → Urządzenia → Dodaj urządzenie): '
stty -echo; read -r CODE; stty echo; echo
cd "$(dirname "$0")/.."
TEST_RUNNER_VESTA_E2E_SERVER="$SERVER" TEST_RUNNER_VESTA_E2E_CODE="$CODE" \
  xcodebuild test -project Vesta.xcodeproj -scheme Vesta \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:VestaTests/LiveReceiptsE2ETests 2>&1 \
  | grep -E "error:|LiveReceiptsE2ETests|skipped|Executed|TEST (SUCCEEDED|FAILED)"
