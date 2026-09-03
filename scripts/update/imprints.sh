#!/usr/bin/env bash
# mod-item-affixes -- UPDATE: Imprints
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."
MODULE_ROOT="$SCRIPT_DIR/../.."
SQL_WORLD="$MODULE_ROOT/data/sql/db-world"
SQL_IMPRINTS="$SQL_WORLD/imprints"

echo "============================================================"
echo " mod-item-affixes -- UPDATE: Imprints"
echo " Run after editing imprint_def.sql, an imprints/*.sql file, or custom_spells.json"
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

echo "Applying imprint SQL to $DB_WORLD..."
for f in "$SQL_IMPRINTS"/*.sql; do
    [ -e "$f" ] || continue
    # imprint_rune_item.sql (singular) is a legacy single-entry (item 601001)
    # superseded by imprint_rune_items.sql (plural, current 602001+ set) --
    # re-applying it would reintroduce a dead item_template row.
    [ "$(basename "$f")" = "imprint_rune_item.sql" ] && continue
    echo "  Applying $(basename "$f")..."
    mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$f"
done
echo "  Done."

if command -v pwsh &>/dev/null; then
    echo "Rebuilding client spell patch..."
    pwsh -File "$MODULE_ROOT/tools/patch_custom_spells.ps1"
else
    echo "Note: pwsh not found -- skipping client patch rebuild (Windows-only step)."
fi

echo "Imprints updated. Restart worldserver to apply."
