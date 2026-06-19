#!/usr/bin/env bash
# mod-item-affixes -- UPDATE: Affixes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."
MODULE_ROOT="$SCRIPT_DIR/../.."
SQL_WORLD="$MODULE_ROOT/data/sql/db-world"

echo "============================================================"
echo " mod-item-affixes -- UPDATE: Affixes"
echo " Run after editing affixes/*.json or class_affixes/*.json"
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

if command -v pwsh &>/dev/null; then
    echo "Regenerating SQL from JSON..."
    pwsh -File "$SCRIPTS_ROOT/build_affixes.ps1"
    pwsh -File "$SCRIPTS_ROOT/build_talent_affixes.ps1"
else
    echo "Note: pwsh not found -- applying pre-built SQL from repo."
fi

mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/affix_template.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" < "$SQL_WORLD/talent_affix_def.sql"
echo "Done. Restart worldserver to apply."
