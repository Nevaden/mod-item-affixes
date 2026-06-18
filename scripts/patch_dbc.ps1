# patch_dbc.ps1
# Reads affixes.json, ensures all active enchant_ids exist in SpellItemEnchantment.dbc
# with the correct display name (overwrites if name changed), then rebuilds client MPQ files.

param(
    [string]$AffixesDir      = "$PSScriptRoot\..\affixes",
    [string]$ClassAffixesDir = "$PSScriptRoot\..\class_affixes",
    # Server bin/ always sits 4 levels above a module's scripts/ folder
    # (<root>\azerothcore\modules\<module>\scripts -> <root>\bin), so this
    # is derived from the module's own location instead of a fixed drive path.
    [string]$ServerDBC       = "$PSScriptRoot\..\..\..\..\bin\data\dbc\SpellItemEnchantment.dbc",
    [string]$MpqBuild        = "$PSScriptRoot\..\tools\mpqbuild.exe",
    # Configure for your installation: the WoW client's Data folder.
    [string]$Patch4          = "E:\servers\Wow\WoW HD\data\patch-4.MPQ",
    [string]$PatchEnUS4      = "E:\servers\Wow\WoW HD\data\enus\patch-enUS-4.MPQ"
)

Write-Host "=== Patching SpellItemEnchantment.dbc ==="

# -- 1. Collect needed enchant IDs from active affixes (stat + class) -------
$allAffixes = [System.Collections.Generic.List[object]]::new()

foreach ($dir in @($AffixesDir, $ClassAffixesDir)) {
    if (-not (Test-Path $dir)) { continue }
    foreach ($file in (Get-ChildItem $dir -Filter "*.json" | Sort-Object Name)) {
        $classJson = Get-Content $file.FullName -Raw | ConvertFrom-Json
        if ($classJson.affixes) { $classJson.affixes | ForEach-Object { $allAffixes.Add($_) } }
    }
}
$json = [PSCustomObject]@{ affixes = @($allAffixes) }

$needed = @{}  # enchant_id -> display_name
foreach ($affix in $json.affixes) {
    if ($affix.tooltip -and $affix.tooltip.enchant_id -and [int]$affix.tooltip.enchant_id -ne 0) {
        $eid  = [int]$affix.tooltip.enchant_id
        $name = if ($affix.tooltip.display_name) { $affix.tooltip.display_name } else { $affix.name }
        $needed[$eid] = $name
    }
}

if ($needed.Count -eq 0) {
    Write-Host "  No enchant_ids in active affixes - rebuilding MPQ only."
} else {
    $idList = ($needed.Keys | Sort-Object | ForEach-Object { "$_ ('$($needed[$_])')" }) -join ', '
    Write-Host "  Active enchant IDs required: $idList"
}

# -- 2. Parse existing DBC --------------------------------------------------
# SpellItemEnchantment.dbc record layout (152 bytes = 38 x uint32):
#   field  0 (offset   0): ID
#   field 14 (offset  56): Name_Lang_enUS string block offset
#   field 30 (offset 120): Name_Lang_Mask = 0xFF3E7E (16712190)
#   all other fields: 0   (display-only; no gameplay effects)

$bytes        = [System.IO.File]::ReadAllBytes($ServerDBC)
$recCount     = [BitConverter]::ToUInt32($bytes, 4)
$fieldCount   = [BitConverter]::ToUInt32($bytes, 8)
$recSize      = [BitConverter]::ToUInt32($bytes, 12)
$strBlockSize = [BitConverter]::ToUInt32($bytes, 16)
$dataStart    = 20
$strBlockOff  = $dataStart + $recCount * $recSize

# Copy mutable record section and string block
$origRecords  = New-Object byte[] ($recCount * $recSize)
[Array]::Copy($bytes, $dataStart, $origRecords, 0, $origRecords.Length)

$origStrBlock = New-Object byte[] $strBlockSize
[Array]::Copy($bytes, $strBlockOff, $origStrBlock, 0, $strBlockSize)

# Build map: id -> record index (0-based)
$idToIdx = @{}
for ($i = 0; $i -lt $recCount; $i++) {
    $id = [int][BitConverter]::ToUInt32($origRecords, $i * $recSize)
    $idToIdx[$id] = $i
}
Write-Host "  DBC currently has $recCount records"

# -- 3. Classify: skip / overwrite / add ------------------------------------
$toUpdate = [System.Collections.Generic.SortedDictionary[int,string]]::new()  # id -> new name
$toAdd    = [System.Collections.Generic.SortedDictionary[int,string]]::new()  # id -> name

foreach ($eid in ($needed.Keys | Sort-Object)) {
    if ($idToIdx.ContainsKey($eid)) {
        # Read the existing name from the string block
        $nameOff = [int][BitConverter]::ToUInt32($origRecords, $idToIdx[$eid] * $recSize + 56)
        $sEnd = $nameOff
        while ($sEnd -lt $origStrBlock.Length -and $origStrBlock[$sEnd] -ne 0) { $sEnd++ }
        $existingName = [System.Text.Encoding]::UTF8.GetString($origStrBlock, $nameOff, $sEnd - $nameOff)

        if ($existingName -ne $needed[$eid]) {
            Write-Host "  ID $eid - overwriting '$existingName' -> '$($needed[$eid])'"
            $toUpdate[$eid] = $needed[$eid]
        } else {
            Write-Host "  ID $eid already correct - skipping"
        }
    } else {
        Write-Host "  ID $eid - adding '$($needed[$eid])'"
        $toAdd[$eid] = $needed[$eid]
    }
}

# -- 4. Apply changes -------------------------------------------------------
if ($toUpdate.Count -eq 0 -and $toAdd.Count -eq 0) {
    Write-Host "  No DBC changes needed."
} else {
    # New strings go at the END of the string block (updates and adds both append here)
    $newStrBytes = [System.Collections.Generic.List[byte[]]]::new()
    $nextStrOff  = $strBlockSize

    # Process updates: append new string, patch record name-offset in-place
    foreach ($eid in $toUpdate.Keys) {
        $nameBytes    = [System.Text.Encoding]::UTF8.GetBytes($toUpdate[$eid])
        $nameWithNull = New-Object byte[] ($nameBytes.Length + 1)
        [Array]::Copy($nameBytes, $nameWithNull, $nameBytes.Length)

        # Patch the record's Name_Lang_enUS offset field (field 14, +56 bytes)
        $recBase = $idToIdx[$eid] * $recSize
        [Array]::Copy([BitConverter]::GetBytes([uint32]$nextStrOff), 0, $origRecords, $recBase + 56, 4)

        $newStrBytes.Add($nameWithNull)
        $nextStrOff += $nameWithNull.Length
    }

    # Process adds: build new records + strings
    $newRecords = [System.Collections.Generic.List[byte[]]]::new()
    foreach ($eid in $toAdd.Keys) {
        $nameBytes    = [System.Text.Encoding]::UTF8.GetBytes($toAdd[$eid])
        $nameWithNull = New-Object byte[] ($nameBytes.Length + 1)
        [Array]::Copy($nameBytes, $nameWithNull, $nameBytes.Length)

        $rec = New-Object byte[] $recSize
        [Array]::Copy([BitConverter]::GetBytes([uint32]$eid),        0, $rec,   0, 4)  # ID
        [Array]::Copy([BitConverter]::GetBytes([uint32]$nextStrOff), 0, $rec,  56, 4)  # Name offset
        [Array]::Copy([BitConverter]::GetBytes([uint32]16712190),    0, $rec, 120, 4)  # Name mask

        $newRecords.Add($rec)
        $newStrBytes.Add($nameWithNull)
        $nextStrOff += $nameWithNull.Length
    }

    # Reassemble: header + (patched) original records + new records + original string block + new strings
    $newRecCount = $recCount + $toAdd.Count
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

    [System.IO.File]::WriteAllBytes($ServerDBC, $out.ToArray())
    Write-Host "  DBC updated: $newRecCount records, $newStrSize bytes string block"
}

# -- 5. Rebuild client MPQ patches ------------------------------------------
Write-Host "  Rebuilding client MPQ files..."
$output = & $MpqBuild build "$ServerDBC" "$Patch4" "$PatchEnUS4" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  patch-4.MPQ      -> $Patch4"
    Write-Host "  patch-enUS-4.MPQ -> $PatchEnUS4"
    Write-Host "  MPQ rebuild complete."
} else {
    Write-Host "  WARNING: mpqbuild.exe failed (exit $LASTEXITCODE)"
    Write-Host $output
    exit 1
}
