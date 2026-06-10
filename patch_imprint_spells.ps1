param(
    [string]$SpellDBC   = "E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc",
    [string]$MpqCreate  = "$PSScriptRoot\tools\mpqcreate.ps1",
    [string]$PatchZ     = "E:\servers\Wow\WoW HD\data\patch-z.MPQ",
    [string]$PatchEnUSZ = "E:\servers\Wow\WoW HD\data\enus\patch-enUS-z.MPQ"
)

$ErrorActionPreference = "Stop"

# patch_imprint_spells.ps1
# Appends custom imprint-system spells to Spell.dbc so the WoW client
# can display them in the spell book, then rebuilds the client MPQ patch.
# Safe to run multiple times -- already-present spells are skipped.
# Shared data dir: E:\servers\Wow\Standard\bin\data (worldserver.conf DataDir)

# Record size for WoW 3.3.5a Spell.dbc = 936 bytes (234 fields x 4 bytes each).
# Field byte offsets derived from SpellEntry struct in DBCStructure.h.
$RECORD_SIZE = 936

# ---------------------------------------------------------------------------
# Spells to inject. Each entry needs Id, Name, AuraDesc, and a Fields table
# mapping byte-offset to uint32 value for every non-zero DBC field.
# ---------------------------------------------------------------------------
$spellName0 = "Celestial Resonance"
$spellDesc0 = "Radiating Holy Nova once per second."

$spellsToAdd = @(
    @{
        Id      = 600002
        Name    = $spellName0
        AuraDesc= $spellDesc0
        Fields  = @{
              0 = [uint32]600002  # ID
             64 = [uint32]2       # Targets: TARGET_FLAG_UNIT
            112 = [uint32]16      # CastingTimeIndex: 1500 ms
            160 = [uint32]31      # DurationIndex: 8000 ms
            184 = [uint32]5       # RangeIndex: 40 yards Long Range
            284 = [uint32]6       # Effect_1: SPELL_EFFECT_APPLY_AURA
            344 = [uint32]25      # EffectImplicitTargetA_1: TARGET_UNIT_TARGET_ANY
            380 = [uint32]226     # EffectApplyAuraName_1: SPELL_AURA_PERIODIC_DUMMY
            392 = [uint32]1000    # EffectAmplitude_1: 1000 ms tick
            532 = [uint32]1874    # SpellIconID: Holy Nova icon
            536 = [uint32]1874    # ActiveIconID
            608 = [uint32]1       # SpellNameFlag: enUS bit
            812 = [uint32]1       # ToolTipFlag: enUS bit
            820 = [uint32]133     # StartRecoveryCategory: standard GCD
            824 = [uint32]1500    # StartRecoveryTime: 1500 ms GCD
            832 = [uint32]6       # SpellFamilyName: SPELLFAMILY_PRIEST
            856 = [uint32]1       # PreventionType: SPELL_PREVENTION_TYPE_SILENCE
            900 = [uint32]2       # SchoolMask: SPELL_SCHOOL_MASK_HOLY
        }
    }
)

Write-Host "=== Patching Spell.dbc for Imprint spells ==="

# ---------------------------------------------------------------------------
# 1. Read existing DBC
# ---------------------------------------------------------------------------
if (!(Test-Path $SpellDBC)) {
    Write-Host "ERROR: Spell.dbc not found at $SpellDBC"
    exit 1
}

$bytes        = [System.IO.File]::ReadAllBytes($SpellDBC)
$recCount     = [BitConverter]::ToUInt32($bytes, 4)
$fieldCount   = [BitConverter]::ToUInt32($bytes, 8)
$recSize      = [BitConverter]::ToUInt32($bytes, 12)
$strBlockSize = [BitConverter]::ToUInt32($bytes, 16)
$dataStart    = 20
$strBlockOff  = $dataStart + $recCount * $recSize

Write-Host "  Source: $recCount records, $fieldCount fields, $recSize bytes/rec"

if ($recSize -ne $RECORD_SIZE) {
    Write-Host "ERROR: Expected record size $RECORD_SIZE, got $recSize -- wrong DBC version?"
    exit 1
}

# Build ID -> record-index lookup
$idToIdx = @{}
for ($i = 0; $i -lt $recCount; $i++) {
    $id = [int][BitConverter]::ToUInt32($bytes, $dataStart + $i * $recSize)
    $idToIdx[$id] = $i
}

# ---------------------------------------------------------------------------
# 2. Determine which spells to add
# ---------------------------------------------------------------------------
$toAdd = [System.Collections.Generic.List[object]]::new()
foreach ($spell in $spellsToAdd) {
    $sid = [int]$spell.Id
    if ($idToIdx.ContainsKey($sid)) {
        Write-Host "  Spell $sid already present -- skipping"
    } else {
        Write-Host "  Queued: spell $sid '$($spell.Name)'"
        $toAdd.Add($spell)
    }
}

if ($toAdd.Count -eq 0) {
    Write-Host "  Nothing to add."
} else {
    Write-Host "  $($toAdd.Count) spell(s) will be added."
}

# ---------------------------------------------------------------------------
# 3. Build new records and strings
# ---------------------------------------------------------------------------
$origRecords  = [byte[]]::new($recCount * $recSize)
[Array]::Copy($bytes, $dataStart, $origRecords, 0, $origRecords.Length)

$origStrBlock = [byte[]]::new($strBlockSize)
[Array]::Copy($bytes, $strBlockOff, $origStrBlock, 0, $strBlockSize)

$newRecords  = [System.Collections.Generic.List[byte[]]]::new()
$newStrBytes = [System.Collections.Generic.List[byte[]]]::new()
$nextStrOff  = $strBlockSize

foreach ($spell in $toAdd) {
    $rec = [byte[]]::new($recSize)

    # Write scalar DBC fields
    foreach ($kv in $spell.Fields.GetEnumerator()) {
        [Array]::Copy([BitConverter]::GetBytes([uint32]$kv.Value), 0, $rec, [int]$kv.Key, 4)
    }

    # SpellName[0] (enUS) at byte offset 544
    $nb = [System.Text.Encoding]::UTF8.GetBytes($spell.Name)
    $nz = [byte[]]::new($nb.Length + 1)
    [Array]::Copy($nb, $nz, $nb.Length)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$nextStrOff), 0, $rec, 544, 4)
    $newStrBytes.Add($nz)
    $nextStrOff += $nz.Length

    # ToolTip[0] (AuraDescription enUS) at byte offset 748
    if ($spell.AuraDesc) {
        $db = [System.Text.Encoding]::UTF8.GetBytes($spell.AuraDesc)
        $dz = [byte[]]::new($db.Length + 1)
        [Array]::Copy($db, $dz, $db.Length)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$nextStrOff), 0, $rec, 748, 4)
        $newStrBytes.Add($dz)
        $nextStrOff += $dz.Length
    }

    $newRecords.Add($rec)
    Write-Host "  Built record for spell $($spell.Id)"
}

# ---------------------------------------------------------------------------
# 4. Reassemble DBC
# ---------------------------------------------------------------------------
$newRecCount = $recCount + $newRecords.Count
$newStrSize  = $nextStrOff

$out = [System.Collections.Generic.List[byte]]::new()
$out.AddRange([System.Text.Encoding]::ASCII.GetBytes("WDBC"))
$out.AddRange([BitConverter]::GetBytes([uint32]$newRecCount))
$out.AddRange([BitConverter]::GetBytes([uint32]$fieldCount))
$out.AddRange([BitConverter]::GetBytes([uint32]$recSize))
$out.AddRange([BitConverter]::GetBytes([uint32]$newStrSize))
$out.AddRange($origRecords)
foreach ($r in $newRecords) { $out.AddRange($r) }
$out.AddRange($origStrBlock)
foreach ($s in $newStrBytes) { $out.AddRange($s) }

[System.IO.File]::WriteAllBytes($SpellDBC, $out.ToArray())
Write-Host "  DBC saved: $newRecCount records, $newStrSize bytes string block"

# ---------------------------------------------------------------------------
# 5. Build client MPQ patches using general-purpose MPQ creator
# ---------------------------------------------------------------------------
Write-Host "  Building MPQ files..."

# Spell.dbc lives in the locale MPQ in WoW 3.3.5a (DBFilesClient\Spell.dbc).
# We put it in BOTH the main and locale patch so whichever the client checks
# first, it finds our version.
$internalPath = "DBFilesClient\Spell.dbc"

& $MpqCreate -SourceFile "$SpellDBC" -InternalPath "$internalPath" -OutputMpq "$PatchZ"
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR creating $PatchZ"; exit 1 }

& $MpqCreate -SourceFile "$SpellDBC" -InternalPath "$internalPath" -OutputMpq "$PatchEnUSZ"
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR creating $PatchEnUSZ"; exit 1 }

Write-Host ""
Write-Host "=== Done. Restart the WoW client to load patch-z. ==="
