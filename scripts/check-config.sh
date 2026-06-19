#!/usr/bin/env bash
# Configuration check for mod-item-affixes (Linux / macOS)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALL_OK=1

pass() { echo "  [OK]  $1"; }
fail() { echo "[FAIL] $1"; ALL_OK=0; }
info() { echo "  [--]  $1"; }

echo "============================================================"
echo " mod-item-affixes -- Configuration Check"
echo "============================================================"
echo

CONFIG="$SCRIPT_DIR/config.sh"
if [ ! -f "$CONFIG" ]; then
    fail "scripts/config.sh not found."
    echo "       Copy scripts/config.sh.example to scripts/config.sh and fill it in."
    exit 1
fi
source "$CONFIG"

# -- MySQL connection ----------------------------------------------------------
if ! command -v mysql &>/dev/null && [ -z "${MYSQL:-}" ]; then
    fail "mysql not found in PATH. Install MySQL client tools."
else
    MYSQL_CMD="${MYSQL:-mysql}"
    if $MYSQL_CMD -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_CHAR" -e "SELECT 1;" &>/dev/null; then
        pass "Characters DB: $DB_CHAR at $MYSQL_HOST"
    else
        fail "Cannot connect to characters DB '$DB_CHAR' at $MYSQL_HOST"
        echo "       Check MYSQL_HOST, MYSQL_USER, MYSQL_PASS, DB_CHAR in scripts/config.sh"
    fi
    if $MYSQL_CMD -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$DB_WORLD" -e "SELECT 1;" &>/dev/null; then
        pass "World DB: $DB_WORLD at $MYSQL_HOST"
    else
        fail "Cannot connect to world DB '$DB_WORLD' at $MYSQL_HOST"
        echo "       Check MYSQL_HOST, MYSQL_USER, MYSQL_PASS, DB_WORLD in scripts/config.sh"
    fi
fi

# -- Server DBC directory -----------------------------------------------------
if [ -z "${SERVER_DBC_DIR:-}" ]; then
    fail "SERVER_DBC_DIR is not set in config.sh"
elif [ ! -f "$SERVER_DBC_DIR/SpellItemEnchantment.dbc" ]; then
    fail "SpellItemEnchantment.dbc not found in SERVER_DBC_DIR: $SERVER_DBC_DIR"
    echo "       Update SERVER_DBC_DIR= in scripts/config.sh"
else
    pass "SERVER_DBC_DIR: $SERVER_DBC_DIR"
fi

# -- CMake (optional) ---------------------------------------------------------
if [ -z "${CMAKE:-}" ]; then
    info "CMAKE not set (optional -- only needed for manage/enable.sh / disable.sh)"
elif ! command -v "$CMAKE" &>/dev/null; then
    echo "  [!!]  CMAKE set but not found: $CMAKE"
else
    pass "CMAKE: $CMAKE"
fi

if [ -z "${BUILD_DIR:-}" ]; then
    info "BUILD_DIR not set (optional -- only needed for manage/enable.sh / disable.sh)"
elif [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "  [!!]  BUILD_DIR set but CMakeCache.txt not found: $BUILD_DIR"
else
    pass "BUILD_DIR: $BUILD_DIR"
fi

echo
if [ "$ALL_OK" -eq 1 ]; then
    echo "  All required checks passed."
    echo "  You are ready to run the install scripts."
else
    echo "  One or more required checks failed."
    echo "  Fix the issues above, then re-run scripts/check-config.sh."
    exit 1
fi
echo "============================================================"
