#!/usr/bin/env bash
# mod-item-affixes -- INSTALL Step 1 of 3: Create DB Schema
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."
MODULE_ROOT="$SCRIPT_DIR/../.."
SQL_CHARS="$MODULE_ROOT/data/sql/db-characters"

echo "============================================================"
echo " mod-item-affixes -- INSTALL Step 1 of 3: Create DB Schema"
echo " Creates mod tables in the characters database."
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: scripts/config.sh not found."
    echo "       Copy scripts/config.sh.example to scripts/config.sh and fill it in."
    exit 1
fi
source "$CONFIG"

echo "Creating character DB tables in $DB_CHAR..."
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_CHAR" < "$SQL_CHARS/item_affix.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_CHAR" < "$SQL_CHARS/item_talent_affix.sql"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_CHAR" < "$SQL_CHARS/item_imprint.sql"
echo "  item_affix, item_talent_affix, item_imprint created."
echo

echo "============================================================"
echo " Step 1 complete."
echo " Next: run install/2-load-data.sh"
echo "============================================================"
