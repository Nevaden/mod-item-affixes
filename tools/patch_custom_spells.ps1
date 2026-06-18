# patch_custom_spells.ps1
# Generalized DBC + MPQ patcher for all custom imprint spells.
#
# Reads ../imprints/custom_spells.json, patches Spell.dbc for every spell
# listed, patches SkillLineAbility.dbc for spells that have a skill_line entry,
# then packages the result into the configured client patch MPQ files.
# Patch slot is auto-detected on first run and saved to scripts\local_config.bat.
#
# Replaces / supersedes patch_spell_dbc.ps1 and patch_mpq_spells.ps1.
# Run this whenever custom_spells.json is modified or a new spell is added.
#
# USAGE (from the module root or from tools/):
#   cd tools
#   .\patch_custom_spells.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths — configurable via environment variables set in scripts\db_config.bat
# ---------------------------------------------------------------------------
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$JsonPath        = Join-Path $ScriptDir "..\imprints\custom_spells.json"
$LocalConfigPath = Join-Path $ScriptDir "..\scripts\local_config.bat"

$ServerDbcDir = $env:SERVER_DBC_DIR
if (-not $ServerDbcDir) { throw "SERVER_DBC_DIR is not set. Add it to scripts\db_config.bat." }
$ServerSpellDb = Join-Path $ServerDbcDir "Spell.dbc"
$ServerSlaDb   = Join-Path $ServerDbcDir "SkillLineAbility.dbc"

function Save-LocalConfigEntry([string]$path, [string]$key, [string]$value) {
    $lines = if (Test-Path $path) {
        @(Get-Content $path | Where-Object { $_ -notmatch "^set $key=" })
    } else {
        @("@echo off",
          "REM Auto-generated -- records patch slots chosen on first run.",
          "REM Delete this file to re-detect. Override in db_config.bat to pin a slot.")
    }
    ($lines + "set $key=$value") | Set-Content $path -Encoding ASCII
}

function Find-FreePatchSuffix([string]$dataDir, [string]$localCfg) {
    $taken = @{}
    Get-ChildItem "$dataDir\patch-?.MPQ" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match "^patch-([A-Za-z])\.MPQ$") { $taken[$Matches[1].ToUpper()] = $true }
    }
    if (Test-Path $localCfg) {
        Get-Content $localCfg | Where-Object { $_ -match "^set PATCH_SUFFIX_\w+=([A-Za-z])$" } |
            ForEach-Object { $taken[$Matches[1].ToUpper()] = $true }
    }
    foreach ($code in 90..65) {
        $letter = [char]$code
        if (-not $taken["$letter"]) { return "$letter" }
    }
    throw "No free patch-[A-Z].MPQ slot in: $dataDir"
}

$ClientDataDir = $env:CLIENT_DATA_DIR
if (-not $ClientDataDir) { throw "CLIENT_DATA_DIR is not set. Add it to scripts\db_config.bat." }

$SpellsSuffix = $env:PATCH_SUFFIX_SPELLS
if (-not $SpellsSuffix) {
    $SpellsSuffix = Find-FreePatchSuffix $ClientDataDir $LocalConfigPath
    Save-LocalConfigEntry $LocalConfigPath "PATCH_SUFFIX_SPELLS" $SpellsSuffix
    Write-Host "  Auto-detected spell patch suffix: $SpellsSuffix (saved to scripts\local_config.bat)"
}

$OutMainMpq   = Join-Path $ClientDataDir "patch-$SpellsSuffix.MPQ"
$OutLocaleMpq = Join-Path $ClientDataDir "enus\patch-enUS-$SpellsSuffix.MPQ"

# ---------------------------------------------------------------------------
# Spell.dbc field indices (0-based). WotLK 3.3.5a: 234 fields, 936 bytes/record.
# Source: src/server/shared/DataStores/DBCStructure.h
# ---------------------------------------------------------------------------
$F_ID                   =   0
$F_DISPEL               =   2
$F_TARGETS              =  16
$F_CASTING_TIME_INDEX   =  28
$F_INTERRUPT_FLAGS      =  31
$F_DURATION_INDEX       =  40
$F_POWER_TYPE           =  41
$F_MANA_COST            =  42
$F_RANGE_INDEX          =  46
$F_EQUIPPED_ITEM_CLASS  =  68
$F_EFFECT_0             =  71
$F_EFFECT_1             =  72
$F_EFFECT_2             =  73
$F_EFFECT_BASE_PTS_0    =  80
$F_EFFECT_BASE_PTS_1    =  81
$F_EFFECT_BASE_PTS_2    =  82
$F_EFFECT_TARGET_A_0    =  86
$F_EFFECT_TARGET_A_1    =  87
$F_EFFECT_TARGET_A_2    =  88
$F_EFFECT_AURA_NAME_0   =  95
$F_EFFECT_AURA_NAME_1   =  96
$F_EFFECT_AURA_NAME_2   =  97
$F_EFFECT_AMPLITUDE_0   =  98
$F_EFFECT_AMPLITUDE_1   =  99
$F_EFFECT_AMPLITUDE_2   = 100
$F_EFF_MULT_VALUE_0     = 101  # float — EffectMultipleValue[0] (chain jump damage multiplier)
$F_EFF_MULT_VALUE_1     = 102
$F_EFF_MULT_VALUE_2     = 103
$F_EFF_CHAIN_TARGETS_0  = 104
$F_EFF_CHAIN_TARGETS_1  = 105
$F_EFF_CHAIN_TARGETS_2  = 106
$F_EFF_TRIGGER_SPELL_0  = 116
$F_EFF_TRIGGER_SPELL_1  = 117
$F_EFF_TRIGGER_SPELL_2  = 118
$F_EFF_DMG_MULT_0       = 216
$F_EFF_DMG_MULT_1       = 217
$F_EFF_DMG_MULT_2       = 218
$F_MANA_COST_PCT        = 204
$F_SPELL_VISUAL_0       = 131
$F_SPELL_ICON_ID        = 133
$F_ACTIVE_ICON_ID       = 134
$F_SPELL_NAME_0         = 136
$F_SPELL_NAME_FLAG      = 152
$F_DESC_0               = 170
$F_DESC_FLAG            = 186
$F_TOOLTIP_0            = 187
$F_TOOLTIP_FLAG         = 203
$F_START_RECOVERY_CAT   = 205
$F_START_RECOVERY_TIME  = 206
$F_SPELL_FAMILY_NAME    = 208
$F_FAMILY_FLAGS_0       = 209
$F_FAMILY_FLAGS_1       = 210
$F_FAMILY_FLAGS_2       = 211
$F_DMG_CLASS            = 213
$F_PREVENTION_TYPE      = 214
$F_SCHOOL_MASK          = 225
$F_EFF_BONUS_MULT_0     = 229
$F_EFF_BONUS_MULT_1     = 230
$F_EFF_BONUS_MULT_2     = 231

# ---------------------------------------------------------------------------
# DBC byte helpers
# ---------------------------------------------------------------------------
function SetU32([byte[]]$rec, [int]$f, [uint32]$v) { [BitConverter]::GetBytes($v).CopyTo($rec, $f * 4) }
function SetI32([byte[]]$rec, [int]$f, [int]$v)    { [BitConverter]::GetBytes([int]$v).CopyTo($rec, $f * 4) }
function SetF32([byte[]]$rec, [int]$f, [float]$v)  { [BitConverter]::GetBytes([float]$v).CopyTo($rec, $f * 4) }
function GetU32([byte[]]$a, [int]$off)              { return [BitConverter]::ToUInt32($a, $off) }

function CombineBytes([byte[]]$a, [byte[]]$b)
{
    $r = New-Object byte[] ($a.Length + $b.Length)
    [Array]::Copy($a, 0, $r, 0, $a.Length)
    [Array]::Copy($b, 0, $r, $a.Length, $b.Length)
    return $r
}

function AppendStr([System.Collections.Generic.List[byte]]$lst, [string]$s)
{
    $off = $lst.Count
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($s)) { $lst.Add($b) }
    $lst.Add([byte]0)
    return [int]$off
}

# ---------------------------------------------------------------------------
# Named-value mappings
# ---------------------------------------------------------------------------
$PowerTypeMap     = @{ mana=0; rage=1; focus=2; energy=3; happiness=4; runes=5; runic_power=6; health=-2 }
$SchoolMap        = @{ physical=1; holy=2; fire=4; nature=8; frost=16; shadow=32; arcane=64 }
$DmgClassMap      = @{ none=0; magic=1; melee=2; ranged=3 }
$PreventionMap    = @{ none=0; silence=1; pacify=2 }
$EffectTypeMap    = @{ DUMMY=3; APPLY_AURA=6; SCHOOL_DAMAGE=2; HEAL=10; ENERGIZE=30; TRIGGER_SPELL=64 }
$AuraTypeMap      = @{ PERIODIC_DUMMY=226; DUMMY=4; PERIODIC_DAMAGE=3; PERIODIC_HEAL=8; DUMMY_AURA=4 }
$TargetMap        = @{ TARGET_SELF=1; TARGET_UNIT_TARGET_ENEMY=6; TARGET_UNIT_TARGET_ALLY=21; TARGET_UNIT_TARGET_ANY=25; TARGET_UNIT_NEARBY_ENEMY=15 }

# Per-effect field index arrays (index 0/1/2)
$EffTypeFields         = @($F_EFFECT_0,             $F_EFFECT_1,             $F_EFFECT_2)
$EffTargetFields       = @($F_EFFECT_TARGET_A_0,    $F_EFFECT_TARGET_A_1,    $F_EFFECT_TARGET_A_2)
$EffAuraFields         = @($F_EFFECT_AURA_NAME_0,   $F_EFFECT_AURA_NAME_1,   $F_EFFECT_AURA_NAME_2)
$EffAmpFields          = @($F_EFFECT_AMPLITUDE_0,   $F_EFFECT_AMPLITUDE_1,   $F_EFFECT_AMPLITUDE_2)
$EffBPFields           = @($F_EFFECT_BASE_PTS_0,    $F_EFFECT_BASE_PTS_1,    $F_EFFECT_BASE_PTS_2)
$EffMultValueFields    = @($F_EFF_MULT_VALUE_0,     $F_EFF_MULT_VALUE_1,     $F_EFF_MULT_VALUE_2)
$EffChainTargetFields  = @($F_EFF_CHAIN_TARGETS_0,  $F_EFF_CHAIN_TARGETS_1,  $F_EFF_CHAIN_TARGETS_2)
$EffTriggerSpellFields = @($F_EFF_TRIGGER_SPELL_0,  $F_EFF_TRIGGER_SPELL_1,  $F_EFF_TRIGGER_SPELL_2)

function BuildSpellRecord([object]$spell, [System.Collections.Generic.List[byte]]$strList, [byte[]]$baseRec)
{
    if ($null -ne $baseRec)
        { $rec = $baseRec.Clone() }
    else
        { $rec = New-Object byte[] 936 }

    SetU32 $rec $F_ID                  ([uint32]$spell.id)
    SetU32 $rec $F_DISPEL              ([uint32]$spell.dispel_type)
    if ($spell.PSObject.Properties['targets_flag'])
        { SetU32 $rec $F_TARGETS ([uint32]$spell.targets_flag) }
    if ($spell.PSObject.Properties['cast_time_index'])
        { SetU32 $rec $F_CASTING_TIME_INDEX ([uint32]$spell.cast_time_index) }
    SetU32 $rec $F_INTERRUPT_FLAGS     ([uint32]$spell.interrupt_flags)
    SetU32 $rec $F_DURATION_INDEX      ([uint32]$spell.duration_index)
    SetI32 $rec $F_EQUIPPED_ITEM_CLASS -1

    # Power type (can be negative for POWER_HEALTH)
    $ptName = [string]$spell.power_type
    if ($PowerTypeMap.ContainsKey($ptName))
    {
        $ptVal = $PowerTypeMap[$ptName]
        if ($ptVal -lt 0) { SetI32 $rec $F_POWER_TYPE [int]$ptVal }
        else              { SetU32 $rec $F_POWER_TYPE ([uint32]$ptVal) }
    }

    # Flat cost (0 when mana_cost_pct is used instead)
    SetU32 $rec $F_MANA_COST  ([uint32]$spell.cost)

    # Percentage mana cost (overrides flat cost when non-zero)
    if ($spell.PSObject.Properties['mana_cost_pct'] -and [int]$spell.mana_cost_pct -gt 0)
    {
        SetU32 $rec $F_MANA_COST_PCT ([uint32]$spell.mana_cost_pct)
        SetU32 $rec $F_MANA_COST 0
    }

    SetU32 $rec $F_RANGE_INDEX ([uint32]$spell.range_index)

    if ($SchoolMap.ContainsKey([string]$spell.school))
        { SetU32 $rec $F_SCHOOL_MASK    ([uint32]$SchoolMap[[string]$spell.school]) }
    if ($DmgClassMap.ContainsKey([string]$spell.damage_class))
        { SetU32 $rec $F_DMG_CLASS      ([uint32]$DmgClassMap[[string]$spell.damage_class]) }
    if ($PreventionMap.ContainsKey([string]$spell.prevention_type))
        { SetU32 $rec $F_PREVENTION_TYPE ([uint32]$PreventionMap[[string]$spell.prevention_type]) }

    if ($spell.PSObject.Properties['visual_id'])
        { SetU32 $rec $F_SPELL_VISUAL_0 ([uint32]$spell.visual_id) }
    SetU32 $rec $F_SPELL_ICON_ID  ([uint32]$spell.icon)
    SetU32 $rec $F_ACTIVE_ICON_ID ([uint32]$spell.icon)

    # Strings — enUS only; name and description always present; aura tooltip optional
    $nameOff = AppendStr $strList ([string]$spell.name)
    $descOff = AppendStr $strList ([string]$spell.description)
    SetU32 $rec $F_SPELL_NAME_0  ([uint32]$nameOff);  SetU32 $rec $F_SPELL_NAME_FLAG 1
    SetU32 $rec $F_DESC_0        ([uint32]$descOff);  SetU32 $rec $F_DESC_FLAG       1

    $aurDesc = [string]$spell.aura_description
    if ($aurDesc -ne "")
    {
        $tooltipOff = AppendStr $strList $aurDesc
        SetU32 $rec $F_TOOLTIP_0    ([uint32]$tooltipOff)
        SetU32 $rec $F_TOOLTIP_FLAG 1
    }

    # GCD
    SetU32 $rec $F_START_RECOVERY_CAT  ([uint32]$spell.gcd_category)
    SetU32 $rec $F_START_RECOVERY_TIME ([uint32]$spell.gcd_ms)

    # Spell family / flags
    SetU32 $rec $F_SPELL_FAMILY_NAME ([uint32]$spell.spell_family)
    SetU32 $rec $F_FAMILY_FLAGS_0    ([uint32]$spell.family_flags[0])
    SetU32 $rec $F_FAMILY_FLAGS_1    ([uint32]$spell.family_flags[1])
    SetU32 $rec $F_FAMILY_FLAGS_2    ([uint32]$spell.family_flags[2])

    # Damage multipliers must be 1.0 (not 0 — 0 zeroes out all effect output)
    SetF32 $rec $F_EFF_DMG_MULT_0   1.0;  SetF32 $rec $F_EFF_DMG_MULT_1   1.0;  SetF32 $rec $F_EFF_DMG_MULT_2   1.0
    SetF32 $rec $F_EFF_BONUS_MULT_0 1.0;  SetF32 $rec $F_EFF_BONUS_MULT_1 1.0;  SetF32 $rec $F_EFF_BONUS_MULT_2 1.0

    # Effects (up to 3)
    $effs = @($spell.effects)
    $maxEffects = [Math]::Min($effs.Count, 3)
    for ($ei = 0; $ei -lt $maxEffects; $ei++)
    {
        $eff = $effs[$ei]

        if ($EffectTypeMap.ContainsKey([string]$eff.type))
            { SetU32 $rec $EffTypeFields[$ei]   ([uint32]$EffectTypeMap[[string]$eff.type]) }

        if ($TargetMap.ContainsKey([string]$eff.target))
            { SetU32 $rec $EffTargetFields[$ei] ([uint32]$TargetMap[[string]$eff.target]) }

        if ($null -ne $eff.aura -and $AuraTypeMap.ContainsKey([string]$eff.aura))
            { SetU32 $rec $EffAuraFields[$ei]   ([uint32]$AuraTypeMap[[string]$eff.aura]) }

        if ($null -ne $eff.amplitude_ms -and [int]$eff.amplitude_ms -gt 0)
            { SetU32 $rec $EffAmpFields[$ei]    ([uint32]$eff.amplitude_ms) }

        if ($null -ne $eff.base_points)
            { SetI32 $rec $EffBPFields[$ei]     ([int]$eff.base_points) }

        # Chain targets (EffectChainTargets) — non-zero enables chaining
        if ($eff.PSObject.Properties['chain_targets'] -and [int]$eff.chain_targets -gt 0)
            { SetU32 $rec $EffChainTargetFields[$ei]  ([uint32]$eff.chain_targets) }

        # Chain jump damage multiplier (EffectMultipleValue, float) — 1.0 = full damage on bounce
        if ($eff.PSObject.Properties['chain_mult'] -and [float]$eff.chain_mult -gt 0.0)
            { SetF32 $rec $EffMultValueFields[$ei]    ([float]$eff.chain_mult) }

        # Trigger spell (EffectTriggerSpell) — fired when effect type is TRIGGER_SPELL (64)
        if ($eff.PSObject.Properties['trigger_spell'] -and [int]$eff.trigger_spell -gt 0)
            { SetU32 $rec $EffTriggerSpellFields[$ei] ([uint32]$eff.trigger_spell) }
    }

    return $rec
}

# ---------------------------------------------------------------------------
# Step 1 — Read and validate Spell.dbc
# ---------------------------------------------------------------------------
Write-Host "=== Step 1: Patching Spell.dbc ==="
if (-not (Test-Path $ServerSpellDb)) { throw "Server Spell.dbc not found: $ServerSpellDb" }

$raw         = [System.IO.File]::ReadAllBytes($ServerSpellDb)
$magic       = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
$recordCount = GetU32 $raw 4
$fieldCount  = GetU32 $raw 8
$recordSize  = GetU32 $raw 12
$strBlockSz  = GetU32 $raw 16

if ($magic      -ne "WDBC") { throw "Bad DBC magic: $magic" }
if ($fieldCount -ne 234)    { throw "Unexpected field count $fieldCount (expected 234)" }
if ($recordSize -ne 936)    { throw "Unexpected record size $recordSize (expected 936)" }
Write-Host "  Source: $recordCount records, $fieldCount fields, $recordSize bytes/rec"

$HEADER_SIZE   = 20
$strBlockStart = $HEADER_SIZE + [int]$recordCount * [int]$recordSize

# Load the string block into a mutable list (we'll append our strings to the end)
$strBytes = New-Object byte[] $strBlockSz
[Array]::Copy($raw, $strBlockStart, $strBytes, 0, [int]$strBlockSz)
if ($strBytes[0] -ne 0) { throw "String block must begin with null terminator" }
$strList = [System.Collections.Generic.List[byte]]::new($strBytes)

# ---------------------------------------------------------------------------
# Load custom_spells.json
# ---------------------------------------------------------------------------
if (-not (Test-Path $JsonPath)) { throw "custom_spells.json not found: $JsonPath" }
$json   = Get-Content $JsonPath -Raw | ConvertFrom-Json
$spells = @($json.spells)
Write-Host "  custom_spells.json: $($spells.Count) spell(s) to patch"

# ---------------------------------------------------------------------------
# Scan for existing IDs and build per-spell records
# ---------------------------------------------------------------------------
$targetIds = @{}
foreach ($sp in $spells) { $targetIds[[uint32]$sp.id] = $true }

# Collect base_spell IDs we need to capture during the DBC scan
$baseSpellIds = @{}
foreach ($sp in $spells)
{
    if ($sp.PSObject.Properties['base_spell'] -and [int]$sp.base_spell -gt 0)
        { $baseSpellIds[[uint32]$sp.base_spell] = $true }
}

$existingOffsets = @{}  # id -> byte offset in $raw
$baseRecords     = @{}  # base spell id -> 936-byte copy of its DBC record
for ($i = 0; $i -lt [int]$recordCount; $i++)
{
    $off = $HEADER_SIZE + $i * [int]$recordSize
    $sid = GetU32 $raw $off
    if ($targetIds.ContainsKey($sid))
    {
        $existingOffsets[$sid] = $off
        Write-Host "  Spell $sid found at record $i -- will replace in-place."
    }
    if ($baseSpellIds.ContainsKey($sid))
    {
        $copy = New-Object byte[] $recordSize
        [Array]::Copy($raw, $off, $copy, 0, $recordSize)
        $baseRecords[$sid] = $copy
    }
}

$newSpells = @()   # spells that need to be appended
$records   = @{}   # id -> 936-byte record
foreach ($sp in $spells)
{
    $baseRec = $null
    if ($sp.PSObject.Properties['base_spell'] -and $baseRecords.ContainsKey([uint32]$sp.base_spell))
        { $baseRec = $baseRecords[[uint32]$sp.base_spell] }
    $records[[uint32]$sp.id] = BuildSpellRecord $sp $strList $baseRec
    if (-not $existingOffsets.ContainsKey([uint32]$sp.id))
        { $newSpells += $sp }
}

$newStrBlock   = $strList.ToArray()
$newStrBlockSz = [uint32]$newStrBlock.Length

# ---------------------------------------------------------------------------
# Assemble the patched DBC bytes
# ---------------------------------------------------------------------------
$newRecordCount = [uint32]($recordCount + $newSpells.Count)

# Start from a copy of the original, replace any existing records in-place
$allData = New-Object byte[] $raw.Length
[Array]::Copy($raw, $allData, $raw.Length)
foreach ($id in $existingOffsets.Keys)
{
    $records[$id].CopyTo($allData, $existingOffsets[$id])
}

# Trim to header + records (discard old string block), then append new records + new string block
$recsEnd     = $HEADER_SIZE + [int]$recordCount * [int]$recordSize
$hdrAndRecs  = New-Object byte[] $recsEnd
[Array]::Copy($allData, 0, $hdrAndRecs, 0, $recsEnd)

$appendBytes = New-Object byte[] 0
foreach ($sp in $newSpells)
{
    $appendBytes = CombineBytes $appendBytes $records[[uint32]$sp.id]
    Write-Host "  Appending new record for spell $($sp.id)."
}

$dbcBytes = CombineBytes (CombineBytes $hdrAndRecs $appendBytes) $newStrBlock

# Update header: record count + string block size
[BitConverter]::GetBytes($newRecordCount).CopyTo($dbcBytes, 4)
[BitConverter]::GetBytes($newStrBlockSz).CopyTo($dbcBytes, 16)
Write-Host "  Patched Spell.dbc: $($dbcBytes.Length) bytes, $newRecordCount records"

# ---------------------------------------------------------------------------
# Step 2 — Patch SkillLineAbility.dbc (only for spells with skill_line set)
# ---------------------------------------------------------------------------
$slaSpells = @($spells | Where-Object { $_.PSObject.Properties['skill_line'] })

$slaBytes = $null
if ($slaSpells.Count -gt 0)
{
    Write-Host ""
    Write-Host "=== Step 2: Patching SkillLineAbility.dbc ($($slaSpells.Count) entr(ies)) ==="

    if (-not (Test-Path $ServerSlaDb)) { throw "SkillLineAbility.dbc not found: $ServerSlaDb" }
    $slaRaw      = [System.IO.File]::ReadAllBytes($ServerSlaDb)
    $slaMagic    = [System.Text.Encoding]::ASCII.GetString($slaRaw, 0, 4)
    $slaRecCount    = GetU32 $slaRaw 4
    $slaFldCount    = GetU32 $slaRaw 8
    $slaRecSize     = GetU32 $slaRaw 12
    $slaStrBlockSz  = GetU32 $slaRaw 16
    if ($slaMagic -ne "WDBC") { throw "Bad SkillLineAbility.dbc magic: $slaMagic" }
    Write-Host "  Source: $slaRecCount records, $slaFldCount fields, $slaRecSize bytes/rec"

    $slaData = New-Object byte[] $slaRaw.Length
    [Array]::Copy($slaRaw, $slaData, $slaRaw.Length)

    $slaNewEntries = [System.Collections.Generic.List[byte[]]]::new()
    foreach ($sp in $slaSpells)
    {
        $entryId = [uint32]$sp.sla_entry_id
        $spellId = [uint32]$sp.id
        $skillLine = [uint32]$sp.skill_line

        $existingSlaOff = -1
        for ($i = 0; $i -lt [int]$slaRecCount; $i++)
        {
            $off = $HEADER_SIZE + $i * [int]$slaRecSize
            if ((GetU32 $slaData $off) -eq $entryId)
            {
                $existingSlaOff = $off
                Write-Host "  SLA entry $entryId already exists at record $i -- replacing."
                break
            }
        }

        $slaRec = New-Object byte[] ([int]$slaRecSize)
        [BitConverter]::GetBytes($entryId).CopyTo($slaRec, 0)   # field 0: ID
        [BitConverter]::GetBytes($skillLine).CopyTo($slaRec, 4) # field 1: SkillLine
        [BitConverter]::GetBytes($spellId).CopyTo($slaRec, 8)   # field 2: Spell
        # field 7: MinSkillLineRank = 1 (matches every real class-ability SLA entry)
        [BitConverter]::GetBytes([uint32]1).CopyTo($slaRec, 28)

        if ($existingSlaOff -ge 0)
        {
            $slaRec.CopyTo($slaData, $existingSlaOff)
            Write-Host "  Updated SLA entry $entryId (spell=$spellId, skillLine=$skillLine)."
        }
        else
        {
            $slaNewEntries.Add($slaRec)
            Write-Host "  Queued new SLA entry $entryId (spell=$spellId, skillLine=$skillLine)."
        }
    }

    # header + (updated) existing records + new records + original string block
    $slaOrigEnd  = $HEADER_SIZE + [int]$slaRecCount * [int]$slaRecSize
    $slaStrBlock = New-Object byte[] ([int]$slaStrBlockSz)
    if ($slaStrBlockSz -gt 0) { [Array]::Copy($slaRaw, $slaOrigEnd, $slaStrBlock, 0, [int]$slaStrBlockSz) }
    $slaHdrRecs = New-Object byte[] $slaOrigEnd
    [Array]::Copy($slaData, 0, $slaHdrRecs, 0, $slaOrigEnd)
    $slaAppend = New-Object byte[] 0
    foreach ($entry in $slaNewEntries) { $slaAppend = CombineBytes $slaAppend $entry }
    $slaBytes = CombineBytes (CombineBytes $slaHdrRecs $slaAppend) $slaStrBlock

    $newSlaCount = [uint32]($slaRecCount + $slaNewEntries.Count)
    [BitConverter]::GetBytes($newSlaCount).CopyTo($slaBytes, 4)
    # string block size unchanged -- no new strings added
    Write-Host "  Patched SkillLineAbility.dbc: $($slaBytes.Length) bytes, $newSlaCount records"
}
else
{
    Write-Host ""
    Write-Host "=== Step 2: No skill_line entries -- SkillLineAbility.dbc unchanged ==="
}

# ---------------------------------------------------------------------------
# Step 3 — Build MPQ crypt table and hash helpers
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 3: Building MPQ ==="

# All arithmetic uses [long] to avoid PowerShell 5.1 uint32 overflow
$CryptTable = New-Object long[] 1280
$ctSeed = [long]0x00100001
for ($i = 0; $i -lt 256; $i++) {
    for ($k = 0; $k -lt 5; $k++) {
        $j = $i + $k * 256
        $ctSeed = ($ctSeed * 125 + 3) % 0x2AAAAB
        $t1 = ($ctSeed -band 0xFFFFL) -shl 16
        $ctSeed = ($ctSeed * 125 + 3) % 0x2AAAAB
        $t2 = $ctSeed -band 0xFFFFL
        $CryptTable[$j] = $t1 -bor $t2
    }
}

$htKeyCheck = [long]([int]0xC3AF3770) -band 0xFFFFFFFFL
$btKeyCheck = [long]([int]0xEC83B3A3) -band 0xFFFFFFFFL

function MpqHash([string]$name, [int]$hashType) {
    $s1 = [long]0x7FED7FED
    $s2 = [long]0xEEEEEEEE
    foreach ($c in $name.ToUpper().ToCharArray()) {
        $ch    = [int][char]$c
        $entry = $CryptTable[$hashType * 256 + $ch]
        $s1    = ($entry -bxor (($s1 + $s2) -band 0xFFFFFFFFL)) -band 0xFFFFFFFFL
        $s2    = ($ch + $s1 + $s2 + ($s2 -shl 5) + 3) -band 0xFFFFFFFFL
    }
    return $s1 -band 0xFFFFFFFFL
}

$htKeyActual = MpqHash "(hash table)"  3
$btKeyActual = MpqHash "(block table)" 3
if ([uint32]$htKeyActual -ne [uint32]$htKeyCheck) { throw "Crypt table self-test FAILED (HT)" }
if ([uint32]$btKeyActual -ne [uint32]$btKeyCheck) { throw "Crypt table self-test FAILED (BT)" }
Write-Host "  Crypt table self-test passed."

function MpqEncrypt([byte[]]$data, [int]$startByte, [int]$dwordCount, [long]$key) {
    $seed = [long]0xEEEEEEEE
    $k    = $key -band 0xFFFFFFFFL
    for ($i = 0; $i -lt $dwordCount; $i++) {
        $byteOff = $startByte + $i * 4
        $val  = [long][BitConverter]::ToUInt32($data, $byteOff)
        $seed = ($seed + $CryptTable[0x400 + ($k -band 0xFFL)]) -band 0xFFFFFFFFL
        $enc  = ($val -bxor (($k + $seed) -band 0xFFFFFFFFL)) -band 0xFFFFFFFFL
        $k    = ((( (-bnot $k) -band 0xFFFFFFFFL) -shl 21) + 0x11111111L) -bor ($k -shr 11)
        $k    = $k -band 0xFFFFFFFFL
        $seed = ($val + $seed + ($seed -shl 5) + 3) -band 0xFFFFFFFFL
        [BitConverter]::GetBytes([uint32]$enc).CopyTo($data, $byteOff)
    }
}

# ---------------------------------------------------------------------------
# Collect MPQ files and compute hash table size
# ---------------------------------------------------------------------------
$InternalSpellPath = "DBFilesClient\Spell.dbc"
$InternalSlaPath   = "DBFilesClient\SkillLineAbility.dbc"

$mpqFiles = [System.Collections.Generic.List[object]]::new()
$mpqFiles.Add([PSCustomObject]@{ InternalPath=$InternalSpellPath; Data=$dbcBytes })
if ($null -ne $slaBytes)
    { $mpqFiles.Add([PSCustomObject]@{ InternalPath=$InternalSlaPath; Data=$slaBytes }) }

# Size the hash table: must be a power of 2, at least 4x the file count
$fileCount = $mpqFiles.Count
$HT_SIZE = 4
while ($HT_SIZE -lt $fileCount * 4) { $HT_SIZE *= 2 }

# Assign each file a slot, detecting collisions
$slots = [System.Collections.Generic.Dictionary[int,int]]::new()
foreach ($f in $mpqFiles)
{
    $slot = [int]((MpqHash $f.InternalPath 0) % $HT_SIZE)
    if ($slots.ContainsValue($slot)) { throw "Hash table slot collision on '$($f.InternalPath)'; increase HT_SIZE ($HT_SIZE)." }
    $slots[$mpqFiles.IndexOf($f)] = $slot
    Write-Host "  '$($f.InternalPath)' -> slot $slot of $HT_SIZE"
}

# ---------------------------------------------------------------------------
# Compute layout: header(32) + file data + hash table + block table
# ---------------------------------------------------------------------------
$FILE_DATA_START = [int]32
$dataOffset = $FILE_DATA_START
$fileLayouts = [System.Collections.Generic.List[object]]::new()
foreach ($f in $mpqFiles)
{
    $fileLayouts.Add([PSCustomObject]@{ Data=$f.Data; Offset=$dataOffset; InternalPath=$f.InternalPath })
    $dataOffset += $f.Data.Length
}
$htOff   = [long]$dataOffset
$btOff   = $htOff + $HT_SIZE * 16
$archSz  = $btOff + $fileCount * 16

Write-Host "  Hash table offset: $htOff   Block table offset: $btOff   Archive size: $archSz"

# ---------------------------------------------------------------------------
# Build hash table
# ---------------------------------------------------------------------------
$htBytes = New-Object byte[] ($HT_SIZE * 16)
for ($i = 0; $i -lt $HT_SIZE; $i++)
    { [BitConverter]::GetBytes([int]-1).CopyTo($htBytes, $i * 16 + 12) }  # all slots FREE

for ($fi = 0; $fi -lt $fileLayouts.Count; $fi++)
{
    $f    = $fileLayouts[$fi]
    $slot = $slots[$fi]
    $hna  = MpqHash $f.InternalPath 1
    $hnb  = MpqHash $f.InternalPath 2
    $so   = $slot * 16
    [BitConverter]::GetBytes([uint32]$hna).CopyTo($htBytes, $so + 0)
    [BitConverter]::GetBytes([uint32]$hnb).CopyTo($htBytes, $so + 4)
    [BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so + 8)   # locale
    [BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so + 10)  # platform
    [BitConverter]::GetBytes([uint32]$fi).CopyTo($htBytes, $so + 12)
}
MpqEncrypt $htBytes 0 ($HT_SIZE * 4) $htKeyActual

# ---------------------------------------------------------------------------
# Build block table
# ---------------------------------------------------------------------------
$MPQ_FILE_EXISTS = [int]([System.Convert]::ToInt32("80000000", 16))
$btBytes = New-Object byte[] ($fileCount * 16)
for ($fi = 0; $fi -lt $fileLayouts.Count; $fi++)
{
    $f   = $fileLayouts[$fi]
    $len = [uint32]$f.Data.Length
    $off = [int]$fi * 16
    [BitConverter]::GetBytes([uint32]$f.Offset).CopyTo($btBytes, $off + 0)
    [BitConverter]::GetBytes($len).CopyTo($btBytes, $off + 4)
    [BitConverter]::GetBytes($len).CopyTo($btBytes, $off + 8)
    [BitConverter]::GetBytes($MPQ_FILE_EXISTS).CopyTo($btBytes, $off + 12)
}
MpqEncrypt $btBytes 0 ($fileCount * 4) $btKeyActual

# ---------------------------------------------------------------------------
# Build MPQ header (32 bytes)
# ---------------------------------------------------------------------------
$mpqHdr = New-Object byte[] 32
[System.Text.Encoding]::ASCII.GetBytes("MPQ").CopyTo($mpqHdr, 0)
$mpqHdr[3] = 0x1A
[BitConverter]::GetBytes([uint32]32).CopyTo($mpqHdr, 4)
[BitConverter]::GetBytes([uint32]$archSz).CopyTo($mpqHdr, 8)
[BitConverter]::GetBytes([uint16]0).CopyTo($mpqHdr, 12)     # format version 0
[BitConverter]::GetBytes([uint16]3).CopyTo($mpqHdr, 14)     # block size shift
[BitConverter]::GetBytes([uint32]$htOff).CopyTo($mpqHdr, 16)
[BitConverter]::GetBytes([uint32]$btOff).CopyTo($mpqHdr, 20)
[BitConverter]::GetBytes([uint32]$HT_SIZE).CopyTo($mpqHdr, 24)
[BitConverter]::GetBytes([uint32]$fileCount).CopyTo($mpqHdr, 28)

# ---------------------------------------------------------------------------
# Assemble final MPQ
# ---------------------------------------------------------------------------
$mpqBytes = New-Object byte[] $archSz
[Array]::Copy($mpqHdr, 0, $mpqBytes, 0, 32)
foreach ($f in $fileLayouts)
    { [Array]::Copy($f.Data, 0, $mpqBytes, $f.Offset, $f.Data.Length) }
[Array]::Copy($htBytes, 0, $mpqBytes, [int]$htOff, $htBytes.Length)
[Array]::Copy($btBytes, 0, $mpqBytes, [int]$btOff, $btBytes.Length)

# ---------------------------------------------------------------------------
# Step 4 — Write output files
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 4: Writing output files ==="

$null = [System.IO.Directory]::CreateDirectory((Split-Path $OutMainMpq  -Parent))
$null = [System.IO.Directory]::CreateDirectory((Split-Path $OutLocaleMpq -Parent))

[System.IO.File]::WriteAllBytes($OutMainMpq,   $mpqBytes)
Write-Host "  Written: $OutMainMpq"
[System.IO.File]::WriteAllBytes($OutLocaleMpq, $mpqBytes)
Write-Host "  Written: $OutLocaleMpq"

Write-Host ""
Write-Host "Done. Restart the WoW client to pick up the new spells from the MPQ patch."
$patchedList = ($spells | ForEach-Object { "$($_.id) ($($_.name))" }) -join ', '
Write-Host "Custom spells patched: $patchedList"
