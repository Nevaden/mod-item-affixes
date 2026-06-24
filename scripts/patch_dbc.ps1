# patch_dbc.ps1
# Reads affixes.json, ensures all active enchant_ids exist in SpellItemEnchantment.dbc
# with the correct display name (overwrites if name changed), then rebuilds client MPQ files.

param(
    [string]$AffixesDir      = "$PSScriptRoot\..\affixes",
    [string]$ClassAffixesDir = "$PSScriptRoot\..\class_affixes"
)

$LocalConfigPath = Join-Path $PSScriptRoot "local_config.bat"

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

$ServerDbcDir = $env:SERVER_DBC_DIR
if (-not $ServerDbcDir) { throw "SERVER_DBC_DIR is not set. Add it to scripts\db_config.bat." }
$ServerDBC = Join-Path $ServerDbcDir "SpellItemEnchantment.dbc"

$ClientDataDir = $env:CLIENT_DATA_DIR
if (-not $ClientDataDir) { throw "CLIENT_DATA_DIR is not set. Add it to scripts\db_config.bat." }

$DbcSuffix = $env:PATCH_SUFFIX_DBC
if (-not $DbcSuffix) {
    $DbcSuffix = Find-FreePatchSuffix $ClientDataDir $LocalConfigPath
    Save-LocalConfigEntry $LocalConfigPath "PATCH_SUFFIX_DBC" $DbcSuffix
    Write-Host "  Auto-detected DBC patch suffix: $DbcSuffix (saved to scripts\local_config.bat)"
}

$PatchOut     = Join-Path $ClientDataDir "patch-$DbcSuffix.MPQ"
$PatchEnUSOut = Join-Path $ClientDataDir "enus\patch-enUS-$DbcSuffix.MPQ"

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

# -- 5. Rebuild client MPQ patches (pure PowerShell — no external tools) ----
Write-Host "  Building client MPQ files..."

# MPQ crypt table
$CryptTable = New-Object long[] 1280
$ctSeed = [long]0x00100001
for ($i = 0; $i -lt 256; $i++) {
    for ($k = 0; $k -lt 5; $k++) {
        $j      = $i + $k * 256
        $ctSeed = ($ctSeed * 125 + 3) % 0x2AAAAB
        $t1     = ($ctSeed -band 0xFFFFL) -shl 16
        $ctSeed = ($ctSeed * 125 + 3) % 0x2AAAAB
        $t2     = $ctSeed -band 0xFFFFL
        $CryptTable[$j] = $t1 -bor $t2
    }
}

function MpqHashDbc([string]$name, [int]$hashType) {
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

function MpqEncryptDbc([byte[]]$data, [int]$startByte, [int]$dwordCount, [long]$key) {
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

$htKey = MpqHashDbc "(hash table)"  3
$btKey = MpqHashDbc "(block table)" 3

# Single file: SpellItemEnchantment.dbc
$internalPath = "DBFilesClient\SpellItemEnchantment.dbc"
$fileData     = [System.IO.File]::ReadAllBytes($ServerDBC)

$HT_SIZE       = 4   # power-of-2 >= 4x file count (1 file -> 4 slots)
$FILE_DATA_START = 32
$htOff  = [long]($FILE_DATA_START + $fileData.Length)
$btOff  = $htOff + $HT_SIZE * 16
$archSz = $btOff + 16   # 1 block table entry

# Hash table
$htBytes = New-Object byte[] ($HT_SIZE * 16)
for ($i = 0; $i -lt $HT_SIZE; $i++)
    { [BitConverter]::GetBytes([int]-1).CopyTo($htBytes, $i * 16 + 12) }
$slot = [int]((MpqHashDbc $internalPath 0) % $HT_SIZE)
$so   = $slot * 16
[BitConverter]::GetBytes([uint32](MpqHashDbc $internalPath 1)).CopyTo($htBytes, $so + 0)
[BitConverter]::GetBytes([uint32](MpqHashDbc $internalPath 2)).CopyTo($htBytes, $so + 4)
[BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so + 8)
[BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so + 10)
[BitConverter]::GetBytes([uint32]0).CopyTo($htBytes, $so + 12)
MpqEncryptDbc $htBytes 0 ($HT_SIZE * 4) $htKey

# Block table
$MPQ_FILE_EXISTS = [int]([System.Convert]::ToInt32("80000000", 16))
$btBytes = New-Object byte[] 16
[BitConverter]::GetBytes([uint32]$FILE_DATA_START).CopyTo($btBytes, 0)
[BitConverter]::GetBytes([uint32]$fileData.Length).CopyTo($btBytes, 4)
[BitConverter]::GetBytes([uint32]$fileData.Length).CopyTo($btBytes, 8)
[BitConverter]::GetBytes($MPQ_FILE_EXISTS).CopyTo($btBytes,        12)
MpqEncryptDbc $btBytes 0 4 $btKey

# MPQ header (32 bytes)
$mpqHdr = New-Object byte[] 32
[System.Text.Encoding]::ASCII.GetBytes("MPQ").CopyTo($mpqHdr, 0)
$mpqHdr[3] = 0x1A
[BitConverter]::GetBytes([uint32]32).CopyTo($mpqHdr,       4)
[BitConverter]::GetBytes([uint32]$archSz).CopyTo($mpqHdr,  8)
[BitConverter]::GetBytes([uint16]0).CopyTo($mpqHdr,       12)
[BitConverter]::GetBytes([uint16]3).CopyTo($mpqHdr,       14)
[BitConverter]::GetBytes([uint32]$htOff).CopyTo($mpqHdr,  16)
[BitConverter]::GetBytes([uint32]$btOff).CopyTo($mpqHdr,  20)
[BitConverter]::GetBytes([uint32]$HT_SIZE).CopyTo($mpqHdr,24)
[BitConverter]::GetBytes([uint32]1).CopyTo($mpqHdr,       28)

# Assemble and write
$mpqBytes = New-Object byte[] $archSz
[Array]::Copy($mpqHdr,   0, $mpqBytes, 0,                    32)
[Array]::Copy($fileData, 0, $mpqBytes, $FILE_DATA_START,      $fileData.Length)
[Array]::Copy($htBytes,  0, $mpqBytes, [int]$htOff,           $htBytes.Length)
[Array]::Copy($btBytes,  0, $mpqBytes, [int]$btOff,           $btBytes.Length)

$null = [System.IO.Directory]::CreateDirectory((Split-Path $PatchOut     -Parent))
$null = [System.IO.Directory]::CreateDirectory((Split-Path $PatchEnUSOut -Parent))
[System.IO.File]::WriteAllBytes($PatchOut,     $mpqBytes)
[System.IO.File]::WriteAllBytes($PatchEnUSOut, $mpqBytes)
Write-Host "  patch-$DbcSuffix.MPQ      -> $PatchOut"
Write-Host "  patch-enUS-$DbcSuffix.MPQ -> $PatchEnUSOut"
Write-Host "  MPQ rebuild complete."
