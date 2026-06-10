# patch_spell_dbc_custom.ps1
# Patches Spell.dbc to add ALL mod-item-affixes custom spells:
#
#   600002  Celestial Resonance  (Priest Holy — applied aura cast by player)
#   600003  Vanishing Backstab   (Rogue   — DUMMY button, learned)
#
# USAGE: .\patch_spell_dbc_custom.ps1
#
# Reads the server's binary Spell.dbc as source.
# Writes patched file to:
#   1. Server DBC dir  — picked up on next worldserver restart
#   2. Client loose-file path — WoW reads DBFilesClient\ files before any MPQ
#
# Running the script multiple times is safe: existing records are replaced in-place,
# new records are appended only once.
#
# After running: rebuild worldserver (if C++ changed), then restart.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ServerDbcPath = "E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc"
$ClientOutDir  = "E:\servers\Wow\WoW HD\Data\DBFilesClient"
$ClientOutPath = Join-Path $ClientOutDir "Spell.dbc"
$ServerOutPath = $ServerDbcPath

# ---------------------------------------------------------------------------
# Field indices (0-based, 4 bytes each) — WotLK 3.3.5a Spell.dbc (234 fields)
# ---------------------------------------------------------------------------
$F_ID                  =   0
$F_TARGETS             =  16
$F_CASTING_TIME_INDEX  =  28
$F_DURATION_INDEX      =  40
$F_POWER_TYPE          =  41
$F_MANA_COST           =  42
$F_RANGE_INDEX         =  46
$F_EQUIPPED_ITEM_CLASS =  68
$F_EFFECT_0            =  71
$F_EFFECT_1_            =  72
$F_EFFECT_2_            =  73
$F_EFFECT_BASE_PTS_0   =  80
$F_EFFECT_TARGET_A_0   =  86
$F_EFFECT_AURA_NAME_0  =  95
$F_EFFECT_AMPLITUDE_0  =  98
$F_EFF_DMG_MULT_0      = 216
$F_EFF_DMG_MULT_1      = 217
$F_EFF_DMG_MULT_2      = 218
$F_SPELL_VISUAL_0      = 131
$F_SPELL_VISUAL_1      = 132
$F_SPELL_ICON_ID       = 133
$F_ACTIVE_ICON_ID      = 134
$F_SPELL_NAME_0        = 136   # enUS string offset (index into string block)
$F_SPELL_NAME_FLAG     = 152
$F_START_RECOVERY_CAT  = 205
$F_START_RECOVERY_TIME = 206
$F_SPELL_FAMILY_NAME   = 208
$F_SCHOOL_MASK         = 225
$F_EFF_BONUS_MULT_0    = 229
$F_EFF_BONUS_MULT_1    = 230
$F_EFF_BONUS_MULT_2    = 231

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function SetU32([byte[]]$rec, [int]$fi, [uint32]$v) { [BitConverter]::GetBytes($v).CopyTo($rec, $fi*4) }
function SetI32([byte[]]$rec, [int]$fi, [int]$v)    { [BitConverter]::GetBytes([int]$v).CopyTo($rec, $fi*4) }
function SetF32([byte[]]$rec, [int]$fi, [float]$v)  { [BitConverter]::GetBytes([float]$v).CopyTo($rec, $fi*4) }
function GetU32([byte[]]$a,  [int]$byteOff)         { [BitConverter]::ToUInt32($a, $byteOff) }

function Combine([byte[]]$a, [byte[]]$b) {
    $r = New-Object byte[] ($a.Length + $b.Length)
    [Array]::Copy($a, 0, $r, 0, $a.Length)
    [Array]::Copy($b, 0, $r, $a.Length, $b.Length)
    return $r
}

# ---------------------------------------------------------------------------
# Read source DBC
# ---------------------------------------------------------------------------
if (-not (Test-Path $ServerDbcPath)) { throw "Not found: $ServerDbcPath" }

$raw         = [System.IO.File]::ReadAllBytes($ServerDbcPath)
$magic       = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
$recCount    = GetU32 $raw 4
$fieldCount  = GetU32 $raw 8
$recSize     = GetU32 $raw 12
$strBlkSize  = GetU32 $raw 16

if ($magic -ne "WDBC")     { throw "Bad magic: $magic" }
if ($fieldCount -ne 234)   { throw "Expected 234 fields, got $fieldCount" }
if ($recSize -ne 936)      { throw "Expected record size 936, got $recSize" }

Write-Host "Source Spell.dbc: $recCount records"

$HEADER     = 20
$strStart   = $HEADER + [int]$recCount * [int]$recSize

# Scan existing IDs into a lookup table (offset -> existing record slot)
$existingSlot = @{}
for ($i = 0; $i -lt [int]$recCount; $i++) {
    $off = $HEADER + $i * [int]$recSize
    $id  = GetU32 $raw $off
    if ($id -ge 600000) { Write-Host "  Already in DBC: spell $id (slot $i)" }
    $existingSlot[$id] = $i
}

# Copy raw bytes for in-place editing
$allBytes = New-Object byte[] $raw.Length
[Array]::Copy($raw, $allBytes, $raw.Length)

# ---------------------------------------------------------------------------
# String block — start from existing, grow as we append
# ---------------------------------------------------------------------------
$strList = [System.Collections.Generic.List[byte]]::new()
$strOrigBytes = New-Object byte[] $strBlkSize
[Array]::Copy($raw, $strStart, $strOrigBytes, 0, [int]$strBlkSize)
$strList.AddRange($strOrigBytes)

function AppendStr([string]$s) {
    $off = $strList.Count
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($s)) { $strList.Add($b) }
    $strList.Add([byte]0)
    return [int]$off
}

# ---------------------------------------------------------------------------
# Define all custom spells
# Each entry: id, name, icon, school, family, targets, castTime, range,
#             equippedClass, effect0, effectAura0, effectAmplitude0,
#             durationIndex, startRecCat, startRecTime, powerType, manaCost
# ---------------------------------------------------------------------------
$spells = @(
    # --- 600002: Celestial Resonance (Priest Holy — targeted APPLY_AURA cast)
    [ordered]@{
        Id              = [uint32]600002
        Name            = "Celestial Resonance"
        Visual0         = [uint32]3077      # Flash Heal cast animation
        IconId          = [uint32]1874      # Holy Nova icon
        SchoolMask      = [uint32]2         # Holy
        FamilyName      = [uint32]6         # SPELLFAMILY_PRIEST
        Targets         = [uint32]2         # unit target
        CastTimeIndex   = [uint32]16        # 1500 ms cast
        RangeIndex      = [uint32]5         # 40 yards
        EquippedClass   = [int]-1
        Effect0         = [uint32]6         # APPLY_AURA
        EffectAura0     = [uint32]226       # PERIODIC_DUMMY
        EffectAmpl0     = [uint32]1000      # 1 s tick
        DurationIndex   = [uint32]31        # 8 s
        StartRecCat     = [uint32]133
        StartRecTime    = [uint32]1500
        PowerType       = [uint32]0         # mana
        ManaCost        = [uint32]0
        TargetA0        = [uint32]25        # TARGET_UNIT_TARGET_ANY
    }
    # --- 600003: Vanishing Backstab (Rogue — DUMMY button, learned)
    [ordered]@{
        Id              = [uint32]600003
        Name            = "Vanishing Backstab"
        Visual0         = [uint32]0         # instant — no cast animation needed
        IconId          = [uint32]243       # Backstab icon
        SchoolMask      = [uint32]1         # Physical
        FamilyName      = [uint32]8         # SPELLFAMILY_ROGUE
        Targets         = [uint32]2         # unit target
        CastTimeIndex   = [uint32]1         # instant
        RangeIndex      = [uint32]34        # 25 yards (Shadowstep range)
        EquippedClass   = [int]-1
        Effect0         = [uint32]3         # DUMMY
        EffectAura0     = [uint32]0
        EffectAmpl0     = [uint32]0
        DurationIndex   = [uint32]0
        StartRecCat     = [uint32]133
        StartRecTime    = [uint32]1000      # Rogue 1 s GCD
        PowerType       = [uint32]3         # energy
        ManaCost        = [uint32]60        # 60 energy
        TargetA0        = [uint32]1         # TARGET_UNIT_CASTER
    }
)

# ---------------------------------------------------------------------------
# For each custom spell: build record and either replace or queue for append
# ---------------------------------------------------------------------------
$newRecords = [System.Collections.Generic.List[byte[]]]::new()

foreach ($sp in $spells) {
    $rec = New-Object byte[] ([int]$recSize)

    $nameOff = AppendStr $sp.Name

    SetU32 $rec $F_ID                 $sp.Id
    SetU32 $rec $F_SCHOOL_MASK        $sp.SchoolMask
    SetU32 $rec $F_TARGETS            $sp.Targets
    SetU32 $rec $F_CASTING_TIME_INDEX $sp.CastTimeIndex
    SetU32 $rec $F_DURATION_INDEX     $sp.DurationIndex
    SetU32 $rec $F_POWER_TYPE         $sp.PowerType
    SetU32 $rec $F_MANA_COST          $sp.ManaCost
    SetU32 $rec $F_RANGE_INDEX        $sp.RangeIndex
    SetI32 $rec $F_EQUIPPED_ITEM_CLASS $sp.EquippedClass
    SetU32 $rec $F_EFFECT_0           $sp.Effect0
    SetU32 $rec $F_EFFECT_1_          0
    SetU32 $rec $F_EFFECT_2_          0
    SetU32 $rec $F_EFFECT_BASE_PTS_0  0
    SetU32 $rec $F_EFFECT_TARGET_A_0  $sp.TargetA0
    SetU32 $rec $F_EFFECT_AURA_NAME_0 $sp.EffectAura0
    SetU32 $rec $F_EFFECT_AMPLITUDE_0 $sp.EffectAmpl0
    SetF32 $rec $F_EFF_DMG_MULT_0     1.0
    SetF32 $rec $F_EFF_DMG_MULT_1     1.0
    SetF32 $rec $F_EFF_DMG_MULT_2     1.0
    SetF32 $rec $F_EFF_BONUS_MULT_0   1.0
    SetF32 $rec $F_EFF_BONUS_MULT_1   1.0
    SetF32 $rec $F_EFF_BONUS_MULT_2   1.0
    SetU32 $rec $F_SPELL_VISUAL_0      $sp.Visual0
    SetU32 $rec $F_SPELL_VISUAL_1      0
    SetU32 $rec $F_SPELL_ICON_ID      $sp.IconId
    SetU32 $rec $F_ACTIVE_ICON_ID     $sp.IconId
    SetU32 $rec $F_SPELL_NAME_0       ([uint32]$nameOff)
    SetU32 $rec $F_SPELL_NAME_FLAG    1
    SetU32 $rec $F_START_RECOVERY_CAT  $sp.StartRecCat
    SetU32 $rec $F_START_RECOVERY_TIME $sp.StartRecTime
    SetU32 $rec $F_SPELL_FAMILY_NAME   $sp.FamilyName

    if ($existingSlot.ContainsKey([uint32]$sp.Id)) {
        # Replace in-place
        $slot = $existingSlot[[uint32]$sp.Id]
        $off  = $HEADER + $slot * [int]$recSize
        $rec.CopyTo($allBytes, $off)
        Write-Host "  Replaced spell $($sp.Id) ($($sp.Name)) at slot $slot"
    } else {
        $newRecords.Add($rec)
        Write-Host "  Queued new spell $($sp.Id) ($($sp.Name))"
    }
}

# ---------------------------------------------------------------------------
# Assemble final file
# ---------------------------------------------------------------------------
$newStrBlock = $strList.ToArray()
$finalRecCount = [uint32]([int]$recCount + $newRecords.Count)

# Build new header
$hdr = New-Object byte[] $HEADER
[System.Text.Encoding]::ASCII.GetBytes("WDBC").CopyTo($hdr, 0)
[BitConverter]::GetBytes($finalRecCount).CopyTo($hdr, 4)
[BitConverter]::GetBytes($fieldCount).CopyTo($hdr, 8)
[BitConverter]::GetBytes($recSize).CopyTo($hdr, 12)
[BitConverter]::GetBytes([uint32]$newStrBlock.Length).CopyTo($hdr, 16)

# Records = original block (with in-place replacements) + appended new records
$origRecLen = [int]$recCount * [int]$recSize
$origRecs   = New-Object byte[] $origRecLen
[Array]::Copy($allBytes, $HEADER, $origRecs, 0, $origRecLen)

$allRecs = $origRecs
foreach ($r in $newRecords) { $allRecs = Combine $allRecs $r }

$outBytes = Combine (Combine $hdr $allRecs) $newStrBlock

Write-Host ""
Write-Host "Final record count: $finalRecCount  |  String block: $($newStrBlock.Length) bytes"

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllBytes($ServerOutPath, $outBytes)
Write-Host "Server DBC written:  $ServerOutPath"

if (-not (Test-Path $ClientOutDir)) {
    $null = [System.IO.Directory]::CreateDirectory($ClientOutDir)
    Write-Host "Created: $ClientOutDir"
}
[System.IO.File]::WriteAllBytes($ClientOutPath, $outBytes)
Write-Host "Client DBC written:  $ClientOutPath"

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  1. Run Rebuild-Server.bat (C++ changes require a rebuild)"
Write-Host "  2. Restart worldserver"
Write-Host "  3. Launch WoW client - 'The Rime Zone' should appear in the Frost spellbook"
