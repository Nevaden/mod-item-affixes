# patch_spell_dbc.ps1
# Patches Spell.dbc to add spell 600002 (Celestial Resonance).
#
# USAGE:
#   .\patch_spell_dbc.ps1
#
# Reads the server's binary Spell.dbc as a source, appends the new entry,
# and writes the patched file to two locations:
#   1. The server's DataDir dbc folder (so the server binary also has it,
#      giving correct InterruptFlags and other base values on restart)
#   2. The WoW client's loose-file path (Data\DBFilesClient\Spell.dbc)
#
# The WoW 3.3.5a client reads loose DBC files from Data\DBFilesClient\ if
# they exist on disk — this overrides the same file inside any MPQ.
# If your client build does NOT support loose files, pack the output into a
# patch MPQ (e.g. patch-4.mpq) using Ladik's MPQ Editor.
#
# Running the script a second time is safe: it detects the existing record
# and replaces it in-place (string block grows slightly each run, harmless).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ServerDbcPath = "E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc"
$ClientOutPath = "E:\servers\Wow\WoW HD\Data\DBFilesClient\Spell.dbc"
# Server output: same file we read from (updates server binary on next restart)
$ServerOutPath = $ServerDbcPath

# ---------------------------------------------------------------------------
# Field indices (0-based) — from AzerothCore src/server/shared/DataStores/DBCStructure.h
# Each field is 4 bytes at offset (fieldIndex * 4) within the record.
# ---------------------------------------------------------------------------
$F_ID                   =   0   # uint32
$F_CATEGORY             =   1   # uint32  — spell category (for category cooldowns)
$F_DISPEL               =   2   # uint32  — DISPEL_MAGIC = 1
$F_TARGETS              =  16   # uint32  — TARGET_FLAG_UNIT = 2
$F_CASTING_TIME_INDEX   =  28   # uint32  — index into SpellCastTimes.dbc
$F_INTERRUPT_FLAGS      =  31   # uint32  — 0xF = interrupted by movement/damage
$F_AURA_INTERRUPT_FLAGS =  32   # uint32  — when the aura itself is removed
$F_DURATION_INDEX       =  40   # uint32  — index into SpellDuration.dbc
$F_POWER_TYPE           =  41   # uint32  — 0 = mana
$F_MANA_COST            =  42   # uint32
$F_RANGE_INDEX          =  46   # uint32  — index into SpellRange.dbc
$F_EQUIPPED_ITEM_CLASS  =  68   # int32   — -1 = no item required
$F_EFFECT_0             =  71   # uint32  — SPELL_EFFECT_APPLY_AURA = 6
$F_EFFECT_1             =  72   # uint32  — 0 (no second effect)
$F_EFFECT_2             =  73   # uint32  — 0
$F_EFFECT_BASE_PTS_0    =  80   # int32   — base points for effect 1
$F_EFFECT_TARGET_A_0    =  86   # uint32  — TARGET_UNIT_TARGET_ANY = 25
$F_EFFECT_TARGET_A_1    =  87   # uint32  — 0
$F_EFFECT_TARGET_A_2    =  88   # uint32  — 0
$F_EFFECT_AURA_NAME_0   =  95   # uint32  — SPELL_AURA_PERIODIC_DUMMY = 226
$F_EFFECT_AMPLITUDE_0   =  98   # uint32  — period in ms
$F_EFF_DMG_MULT_0       = 216   # float   — EffectDamageMultiplier[0]
$F_EFF_DMG_MULT_1       = 217   # float
$F_EFF_DMG_MULT_2       = 218   # float
$F_SPELL_ICON_ID        = 133   # uint32
$F_ACTIVE_ICON_ID       = 134   # uint32
$F_SPELL_NAME_0         = 136   # uint32  — enUS string offset (fields 136-151 = 16 locales)
$F_SPELL_NAME_FLAG      = 152   # uint32  — locale availability bitmask
$F_RANK_FLAG            = 169   # uint32  — no rank string
$F_DESC_0               = 170   # uint32  — enUS description string offset (fields 170-185)
$F_DESC_FLAG            = 186   # uint32
$F_TOOLTIP_0            = 187   # uint32  — enUS aura tooltip offset (fields 187-202)
$F_TOOLTIP_FLAG         = 203   # uint32
$F_MANA_COST_PCT        = 204   # uint32
$F_START_RECOVERY_CAT   = 205   # uint32  — GCD category
$F_START_RECOVERY_TIME  = 206   # uint32  — GCD duration in ms
$F_MAX_TARGET_LEVEL     = 207   # uint32
$F_SPELL_FAMILY_NAME    = 208   # uint32  — SPELLFAMILY_PRIEST = 6
$F_FAMILY_FLAGS_0       = 209   # uint32  — SpellFamilyFlags (flag96, 3 × uint32)
$F_FAMILY_FLAGS_1       = 210
$F_FAMILY_FLAGS_2       = 211
$F_MAX_AFFECTED_TARGETS = 212   # uint32
$F_DMG_CLASS            = 213   # uint32  — SPELL_DAMAGE_CLASS_MAGIC = 2
$F_PREVENTION_TYPE      = 214   # uint32  — SPELL_PREVENTION_TYPE_SILENCE = 1
$F_SCHOOL_MASK          = 225   # uint32  — SPELL_SCHOOL_MASK_HOLY = 2
$F_EFF_BONUS_MULT_0     = 229   # float   — EffectBonusMultiplier[0]
$F_EFF_BONUS_MULT_1     = 230   # float
$F_EFF_BONUS_MULT_2     = 231   # float

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function SetU32([byte[]]$rec, [int]$fieldIdx, [uint32]$value)
{
    [BitConverter]::GetBytes($value).CopyTo($rec, $fieldIdx * 4)
}

function SetI32([byte[]]$rec, [int]$fieldIdx, [int]$value)
{
    [BitConverter]::GetBytes([int]$value).CopyTo($rec, $fieldIdx * 4)
}

function SetF32([byte[]]$rec, [int]$fieldIdx, [float]$value)
{
    [BitConverter]::GetBytes([float]$value).CopyTo($rec, $fieldIdx * 4)
}

function GetU32([byte[]]$arr, [int]$byteOffset)
{
    return [BitConverter]::ToUInt32($arr, $byteOffset)
}

function CombineBytes([byte[]]$a, [byte[]]$b)
{
    $result = New-Object byte[] ($a.Length + $b.Length)
    [Array]::Copy($a, 0, $result, 0, $a.Length)
    [Array]::Copy($b, 0, $result, $a.Length, $b.Length)
    return $result
}

# ---------------------------------------------------------------------------
# Read source DBC
# ---------------------------------------------------------------------------
if (-not (Test-Path $ServerDbcPath)) { throw "Not found: $ServerDbcPath" }

$raw = [System.IO.File]::ReadAllBytes($ServerDbcPath)
$magic           = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
$recordCount     = GetU32 $raw 4
$fieldCount      = GetU32 $raw 8
$recordSize      = GetU32 $raw 12
$stringBlockSize = GetU32 $raw 16

if ($magic    -ne "WDBC") { throw "Bad DBC magic: $magic" }
if ($fieldCount -ne 234)  { throw "Unexpected field count $fieldCount (expected 234 for WotLK Spell.dbc)" }
if ($recordSize -ne 936)  { throw "Unexpected record size $recordSize (expected 936)" }

Write-Host "Loaded Spell.dbc: $recordCount records, field_count=$fieldCount, record_size=$recordSize"

$dataStart        = 20
$strBlockStart    = $dataStart + [int]$recordCount * [int]$recordSize

# ---------------------------------------------------------------------------
# Scan for existing spell 600002
# ---------------------------------------------------------------------------
$TARGET_SPELL_ID       = [uint32]600002
$existingRecordOffset  = -1

for ($i = 0; $i -lt [int]$recordCount; $i++)
{
    $off = $dataStart + $i * [int]$recordSize
    if ((GetU32 $raw $off) -eq $TARGET_SPELL_ID)
    {
        $existingRecordOffset = $off
        Write-Host "Spell $TARGET_SPELL_ID found at record index $i — will replace in-place."
        break
    }
}

# ---------------------------------------------------------------------------
# Build the expanded string block (append our strings at the end)
# ---------------------------------------------------------------------------
$strBlockBytes = New-Object byte[] $stringBlockSize
[Array]::Copy($raw, $strBlockStart, $strBlockBytes, 0, [int]$stringBlockSize)

if ($strBlockBytes.Length -eq 0 -or $strBlockBytes[0] -ne 0)
    { throw "String block does not begin with null terminator" }

$strList = [System.Collections.Generic.List[byte]]::new($strBlockBytes)

function AppendStr([System.Collections.Generic.List[byte]]$list, [string]$s)
{
    $offset = $list.Count
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($s)) { $list.Add($b) }
    $list.Add([byte]0)  # null terminator
    return [int]$offset
}

$nameOffset    = AppendStr $strList "Celestial Resonance"
$descOffset    = AppendStr $strList "Applies Celestial Resonance to the target. Holy Nova radiates from their position each second for 8 sec."
$tooltipOffset = AppendStr $strList "Radiating Holy Nova once per second."

$newStrBlock     = $strList.ToArray()
$newStrBlockSize = [uint32]$newStrBlock.Length

# ---------------------------------------------------------------------------
# Build the spell record (936 bytes, zero-initialised, then fill fields)
# ---------------------------------------------------------------------------
$rec = New-Object byte[] 936

SetU32 $rec $F_ID                   $TARGET_SPELL_ID
SetU32 $rec $F_CATEGORY             0               # no category cooldown
SetU32 $rec $F_DISPEL               1               # DISPEL_MAGIC — makes the aura magic-dispellable
SetU32 $rec $F_TARGETS              2               # TARGET_FLAG_UNIT — requires a unit target
SetU32 $rec $F_CASTING_TIME_INDEX   16              # 1500 ms cast time
SetU32 $rec $F_INTERRUPT_FLAGS      15              # 0xF — cast interrupted by movement / damage
SetU32 $rec $F_AURA_INTERRUPT_FLAGS 0               # aura not auto-removed by any game event
SetU32 $rec $F_DURATION_INDEX       31              # 8000 ms duration
SetU32 $rec $F_POWER_TYPE           0               # mana
SetU32 $rec $F_MANA_COST            0               # server controls cost via spell_dbc SQL

SetU32 $rec $F_RANGE_INDEX          5               # 40 yards ("Long Range")
SetI32 $rec $F_EQUIPPED_ITEM_CLASS  -1              # no item required

# Effect 1: SPELL_EFFECT_APPLY_AURA (6) → SPELL_AURA_PERIODIC_DUMMY (226), 1 s period
SetU32 $rec $F_EFFECT_0             6               # SPELL_EFFECT_APPLY_AURA
SetU32 $rec $F_EFFECT_1             0
SetU32 $rec $F_EFFECT_2             0
SetU32 $rec $F_EFFECT_BASE_PTS_0    0
SetU32 $rec $F_EFFECT_TARGET_A_0    25              # TARGET_UNIT_TARGET_ANY
SetU32 $rec $F_EFFECT_TARGET_A_1    0
SetU32 $rec $F_EFFECT_TARGET_A_2    0
SetU32 $rec $F_EFFECT_AURA_NAME_0   226             # SPELL_AURA_PERIODIC_DUMMY
SetU32 $rec $F_EFFECT_AMPLITUDE_0   1000            # fire every 1000 ms

# Damage multipliers — must be 1.0 (float), not 0 which would zero out damage
SetF32 $rec $F_EFF_DMG_MULT_0       1.0
SetF32 $rec $F_EFF_DMG_MULT_1       1.0
SetF32 $rec $F_EFF_DMG_MULT_2       1.0
SetF32 $rec $F_EFF_BONUS_MULT_0     1.0
SetF32 $rec $F_EFF_BONUS_MULT_1     1.0
SetF32 $rec $F_EFF_BONUS_MULT_2     1.0

# Icons — 1874 = Spell_Holy_HolyNova
SetU32 $rec $F_SPELL_ICON_ID        1874
SetU32 $rec $F_ACTIVE_ICON_ID       1874

# Strings — enUS locale (index 0) only; other 15 locales stay at 0 = empty string
SetU32 $rec $F_SPELL_NAME_0         ([uint32]$nameOffset)
SetU32 $rec $F_SPELL_NAME_FLAG      1               # bit 0 = enUS available
# Rank: all zero (no rank string)
SetU32 $rec $F_RANK_FLAG            0
# Description (shown in spellbook tooltip)
SetU32 $rec $F_DESC_0               ([uint32]$descOffset)
SetU32 $rec $F_DESC_FLAG            1
# Tooltip (shown on buff/debuff mouseover)
SetU32 $rec $F_TOOLTIP_0            ([uint32]$tooltipOffset)
SetU32 $rec $F_TOOLTIP_FLAG         1

# GCD — standard 1.5 s global cooldown
SetU32 $rec $F_START_RECOVERY_CAT   133
SetU32 $rec $F_START_RECOVERY_TIME  1500

# Classification
SetU32 $rec $F_SPELL_FAMILY_NAME    6               # SPELLFAMILY_PRIEST
SetU32 $rec $F_FAMILY_FLAGS_0       0
SetU32 $rec $F_FAMILY_FLAGS_1       0
SetU32 $rec $F_FAMILY_FLAGS_2       0
SetU32 $rec $F_MAX_AFFECTED_TARGETS 0
SetU32 $rec $F_DMG_CLASS            2               # SPELL_DAMAGE_CLASS_MAGIC
SetU32 $rec $F_PREVENTION_TYPE      1               # SPELL_PREVENTION_TYPE_SILENCE
SetU32 $rec $F_SCHOOL_MASK          2               # SPELL_SCHOOL_MASK_HOLY

# ---------------------------------------------------------------------------
# Assemble output bytes
# ---------------------------------------------------------------------------
$HEADER_SIZE = 20

if ($existingRecordOffset -ge 0)
{
    # Replace existing record in-place.
    # Copy all original bytes, overwrite the target record, then swap in the
    # expanded string block.
    $allData = New-Object byte[] $raw.Length
    [Array]::Copy($raw, $allData, $raw.Length)
    $rec.CopyTo($allData, $existingRecordOffset)

    # Update StringBlockSize in header
    [BitConverter]::GetBytes($newStrBlockSize).CopyTo($allData, 16)

    # Slice off original string block (keep header + all records)
    $recordsEndOffset = $HEADER_SIZE + [int]$recordCount * [int]$recordSize
    $headerAndRecords = New-Object byte[] $recordsEndOffset
    [Array]::Copy($allData, 0, $headerAndRecords, 0, $recordsEndOffset)

    $outBytes = CombineBytes $headerAndRecords $newStrBlock
    Write-Host "Updated existing record for spell $TARGET_SPELL_ID."
}
else
{
    # Append new record after all existing records.
    $newRecordCount = [uint32]($recordCount + 1)

    # Build new header
    $hdr = New-Object byte[] $HEADER_SIZE
    [System.Text.Encoding]::ASCII.GetBytes("WDBC").CopyTo($hdr, 0)
    [BitConverter]::GetBytes($newRecordCount).CopyTo($hdr, 4)
    [BitConverter]::GetBytes($fieldCount).CopyTo($hdr, 8)
    [BitConverter]::GetBytes($recordSize).CopyTo($hdr, 12)
    [BitConverter]::GetBytes($newStrBlockSize).CopyTo($hdr, 16)

    # All original records
    $origRecordsLen = [int]$recordCount * [int]$recordSize
    $origRecords = New-Object byte[] $origRecordsLen
    [Array]::Copy($raw, $HEADER_SIZE, $origRecords, 0, $origRecordsLen)

    $outBytes = CombineBytes (CombineBytes (CombineBytes $hdr $origRecords) $rec) $newStrBlock
    Write-Host "Appended new record for spell $TARGET_SPELL_ID (total records: $newRecordCount)."
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------

# 1. Server binary DBC (picked up on next worldserver restart)
[System.IO.File]::WriteAllBytes($ServerOutPath, $outBytes)
Write-Host "Server DBC written: $ServerOutPath"

# 2. Client loose-file DBC
$clientDir = Split-Path $ClientOutPath -Parent
if (-not (Test-Path $clientDir))
{
    $null = [System.IO.Directory]::CreateDirectory($clientDir)
    Write-Host "Created client directory: $clientDir"
}
[System.IO.File]::WriteAllBytes($ClientOutPath, $outBytes)
Write-Host "Client DBC written: $ClientOutPath"

Write-Host ""
Write-Host "Done. Restart the worldserver to apply the server-side binary DBC update."
Write-Host "The client reads the loose file automatically if it supports DBFilesClient\ overrides."
Write-Host "If the spell name still shows as 'Unknown' in-game, pack the file into a patch MPQ."
