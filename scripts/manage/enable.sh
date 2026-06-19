#!/usr/bin/env bash
# mod-item-affixes -- MANAGE: Enable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."

echo "============================================================"
echo " mod-item-affixes -- MANAGE: Enable"
echo " All DB data is preserved."
echo " STOP worldserver before continuing."
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

if [ -z "${CMAKE:-}" ] || [ -z "${BUILD_DIR:-}" ]; then
    echo "ERROR: CMAKE and BUILD_DIR must be set in config.sh."
    exit 1
fi

"$CMAKE" -DDISABLED_AC_MODULES="" -DMODULE_MOD-ITEM-AFFIXES=default "$BUILD_DIR"
"$CMAKE" --build "$BUILD_DIR" --target worldserver --config RelWithDebInfo
"$CMAKE" --install "$BUILD_DIR" --config RelWithDebInfo
echo "mod-item-affixes ENABLED. Start worldserver to apply."
