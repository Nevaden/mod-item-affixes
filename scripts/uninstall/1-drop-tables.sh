#!/usr/bin/env bash
# mod-item-affixes -- UNINSTALL Step 1 of 3: Drop Tables
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."

echo "============================================================"
echo " mod-item-affixes -- UNINSTALL Step 1 of 3: Drop Tables"
echo
echo " WARNING: Permanently deletes ALL player affix data."
echo "   Drops from characters DB: item_affix, item_talent_affix,"
echo "   item_imprint"
echo
echo " This cannot be undone."
echo "============================================================"
echo
read -rp "Type UNINSTALL to confirm (Ctrl+C to cancel): " CONFIRM
if [ "$CONFIRM" != "UNINSTALL" ]; then
    echo "Cancelled. No changes made."
    exit 0
fi
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: scripts/config.sh not found."
    exit 1
fi
source "$CONFIG"

echo "Dropping character DB tables from $DB_CHAR..."
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_CHAR" -e \
  "DROP TABLE IF EXISTS item_affix, item_talent_affix, item_imprint;"
echo "  Dropped: item_affix, item_talent_affix, item_imprint"
echo

echo "============================================================"
echo " Step 1 complete."
echo " Next: run uninstall/2-clean-world-data.sh"
echo "============================================================"
