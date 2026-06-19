#!/usr/bin/env bash
# mod-item-affixes -- UPDATE: Imprints
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."
MODULE_ROOT="$SCRIPT_DIR/../.."
SQL_WORLD="$MODULE_ROOT/data/sql/db-world"

echo "============================================================"
echo " mod-item-affixes -- UPDATE: Imprints"
echo " Run after editing imprint_def.sql or custom_spells.json"
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

echo "Applying imprint SQL to $DB_WORLD..."
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/imprint_def.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/imprint_rune_items.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_script_names_imprint.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_celestial_resonance.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_vanishing_backstab.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_arcane_shot_variants.sql"
echo "  Done."

if command -v pwsh &>/dev/null; then
    echo "Rebuilding client spell patch..."
    pwsh -File "$MODULE_ROOT/tools/patch_custom_spells.ps1"
else
    echo "Note: pwsh not found -- skipping client patch rebuild (Windows-only step)."
fi

echo "Imprints updated. Restart worldserver to apply."
