#!/usr/bin/env bash
# mod-item-affixes -- RESET PLAYER AFFIXES
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."
MODULE_ROOT="$SCRIPT_DIR/../.."
SQL_RESET="$MODULE_ROOT/data/sql/db-characters/reset_item_affixes.sql"

echo "============================================================"
echo " mod-item-affixes -- RESET PLAYER AFFIXES"
echo
echo " WARNING: Deletes ALL rows from item_affix."
echo " Every player item loses its rolled affix data."
echo " Use only for testing or after a major affix rebalance."
echo "============================================================"
echo
read -rp "Type RESET to confirm (Ctrl+C to cancel): " CONFIRM
if [ "$CONFIRM" != "RESET" ]; then echo "Cancelled."; exit 0; fi
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_CHAR" < "$SQL_RESET"
echo "Done. All item_affix rows cleared."
echo "Restart worldserver -- items will re-roll on next login or pickup."
