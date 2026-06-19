#!/usr/bin/env bash
# mod-item-affixes -- UNINSTALL Step 2 of 3: Clean World Data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR/.."

echo "============================================================"
echo " mod-item-affixes -- UNINSTALL Step 2 of 3: Clean World Data"
echo "============================================================"
echo

CONFIG="$SCRIPTS_ROOT/config.sh"
if [ ! -f "$CONFIG" ]; then echo "ERROR: scripts/config.sh not found."; exit 1; fi
source "$CONFIG"

RUNE_ITEM_ID_END=$((RUNE_ITEM_ID_START + 99))
IMPRINT_SPELL_ID_END=$((IMPRINT_SPELL_ID_START + 99))
SPELLSWAP_SPELL_ID_END=$((SPELLSWAP_SPELL_ID_START + 99))

echo "Dropping world tables from $DB_WORLD..."
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" -e \
  "DROP TABLE IF EXISTS affix_template, talent_affix_def, imprint_def;"
echo "  Dropped: affix_template, talent_affix_def, imprint_def"

echo "Removing mod rows from shared tables..."
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" -e \
  "DELETE FROM item_template WHERE entry BETWEEN $RUNE_ITEM_ID_START AND $RUNE_ITEM_ID_END;"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" -e \
  "DELETE FROM spell_dbc WHERE Id BETWEEN $IMPRINT_SPELL_ID_START AND $IMPRINT_SPELL_ID_END OR Id BETWEEN $SPELLSWAP_SPELL_ID_START AND $SPELLSWAP_SPELL_ID_END;"
mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" -e \
  "DELETE FROM spell_script_names WHERE spell_id BETWEEN $IMPRINT_SPELL_ID_START AND $IMPRINT_SPELL_ID_END OR spell_id BETWEEN $SPELLSWAP_SPELL_ID_START AND $SPELLSWAP_SPELL_ID_END;"
echo "  Done."
echo

echo "============================================================"
echo " Step 2 complete."
echo
echo " Manual client cleanup still required:"
echo "   - Delete MPQ files from WoW Data folder (Windows only)"
echo "     Check scripts/local_config.bat for suffix letters"
echo "   - Remove addon: Interface/AddOns/ItemAffixes/"
echo
echo " Next: run uninstall/3-rebuild-server.sh"
echo "============================================================"
