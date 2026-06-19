#!/usr/bin/env bash
# mod-item-affixes -- UNINSTALL Step 3 of 3: Rebuild Server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."

echo "============================================================"
echo " mod-item-affixes -- UNINSTALL Step 3 of 3: Rebuild Server"
echo " Excludes the module from cmake and rebuilds worldserver."
echo " STOP worldserver before continuing."
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

if [ -z "${CMAKE:-}" ] || [ -z "${BUILD_DIR:-}" ]; then
    echo "SKIPPED: CMAKE or BUILD_DIR not set in config.sh."
    echo "         Run manually:"
    echo "           cmake -DDISABLED_AC_MODULES=mod-item-affixes \\"
    echo "                 -DMODULE_MOD-ITEM-AFFIXES=disabled <build_dir>"
    echo "           cmake --build <build_dir> --target worldserver"
    echo "           cmake --install <build_dir>"
    exit 0
fi

echo "Reconfiguring CMake..."
"$CMAKE" -DDISABLED_AC_MODULES=mod-item-affixes -DMODULE_MOD-ITEM-AFFIXES=disabled "$BUILD_DIR"

echo "Building worldserver..."
"$CMAKE" --build "$BUILD_DIR" --target worldserver --config RelWithDebInfo

echo "Installing..."
"$CMAKE" --install "$BUILD_DIR" --config RelWithDebInfo

echo
echo "Worldserver rebuilt without mod-item-affixes."
echo "Uninstall complete. You can now start the worldserver."
