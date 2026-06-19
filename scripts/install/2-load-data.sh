#!/usr/bin/env bash
# mod-item-affixes -- INSTALL Step 2 of 3: Load Data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."
MODULE_ROOT="$SCRIPT_DIR/../.."
SQL_WORLD="$MODULE_ROOT/data/sql/db-world"

echo "============================================================"
echo " mod-item-affixes -- INSTALL Step 2 of 3: Load Data"
echo " Applies affix, imprint, and spell data to the world DB."
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: scripts/config.sh not found."
    exit 1
fi
source "$CONFIG"

# If pwsh (PowerShell Core) is available, regenerate SQL from JSON first.
# Otherwise apply the pre-built SQL already in the repo.
if command -v pwsh &>/dev/null; then
    echo "Regenerating SQL from JSON definitions (pwsh found)..."
    pwsh -File "$SCRIPTS_ROOT/build_affixes.ps1"
    pwsh -File "$SCRIPTS_ROOT/build_talent_affixes.ps1"
    echo "  SQL regenerated."
else
    echo "Note: pwsh not found -- applying pre-built SQL from repo."
    echo "      Install PowerShell Core (pwsh) if you've changed affixes JSON."
fi
echo

echo "Applying world DB data to $DB_WORLD..."
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/affix_template.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/talent_affix_def.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/imprint_def.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/imprint_rune_items.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_script_names_imprint.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_celestial_resonance.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_vanishing_backstab.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/spell_dbc_arcane_shot_variants.sql"
echo "  All data applied."
echo

echo "============================================================"
echo " Step 2 complete. Start the worldserver to verify."
echo " Client patch (MPQ/DBC) is Windows-only:"
echo "   scripts/install/3-patch-client.bat"
echo "============================================================"
