#!/usr/bin/env bash
# mod-item-affixes -- UPDATE: All
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."
MODULE_ROOT="$SCRIPT_DIR/../.."
SQL_WORLD="$MODULE_ROOT/data/sql/db-world"

echo "============================================================"
echo " mod-item-affixes -- UPDATE: All"
echo " Run after: git pull"
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

echo "[1/2] Generating and applying affix data..."
if command -v pwsh &>/dev/null; then
    pwsh -File "$SCRIPTS_ROOT/build_affixes.ps1"
    pwsh -File "$SCRIPTS_ROOT/build_talent_affixes.ps1"
else
    echo "  Note: pwsh not found -- applying pre-built SQL from repo."
fi
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/affix_template.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/talent_affix_def.sql"
echo "  Done."
echo

echo "[2/2] Applying imprint data..."
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/imprint_def.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/imprint_rune_items.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_script_names_imprint.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_celestial_resonance.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_vanishing_backstab.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_arcane_shot_variants.sql"
echo "  Done. (Client patch rebuild requires Windows -- see update/client-patch.bat)"
echo

echo "All updates applied. Restart worldserver to apply changes."
