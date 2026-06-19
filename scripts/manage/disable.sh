#!/usr/bin/env bash
# mod-item-affixes -- MANAGE: Disable (data preserved)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."

echo "============================================================"
echo " mod-item-affixes -- MANAGE: Disable (data preserved)"
echo " Re-enable at any time with manage/enable.sh."
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

"$CMAKE" -DDISABLED_AC_MODULES=mod-item-affixes -DMODULE_MOD-ITEM-AFFIXES=disabled "$BUILD_DIR"
"$CMAKE" --build "$BUILD_DIR" --target worldserver --config RelWithDebInfo
"$CMAKE" --install "$BUILD_DIR" --config RelWithDebInfo
echo "mod-item-affixes DISABLED. Data preserved. Run enable.sh to re-enable."
