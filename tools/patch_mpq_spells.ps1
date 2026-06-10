# patch_mpq_spells.ps1
# Creates patch-z.MPQ and patch-enUS-z.MPQ containing Celestial Resonance (spell 600002).
#
# USAGE:
#   .\patch_mpq_spells.ps1
#
# Reads Spell.dbc from the server's shared DBC directory, appends spell 600002,
# then packages the result in new MPQ v1 archives placed in the WoW HD client's
# data directories. The -z suffix gives higher priority than the flying mod's -y patches.
#
# Running a second time is safe: detects and replaces the existing 600002 record.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ServerDbcPath = "E:\servers\Wow\Standard\bin\data\dbc\Spell.dbc"
$OutMainMpq    = "E:\servers\Wow\WoW HD\data\patch-z.MPQ"
$OutLocaleMpq  = "E:\servers\Wow\WoW HD\data\enus\patch-enUS-z.MPQ"
$InternalPath  = "DBFilesClient\Spell.dbc"   # path WoW uses internally to look up the DBC

# ---------------------------------------------------------------------------
# DBC field indices (0-based)  -  Spell.dbc WotLK 3.3.5a: 234 fields, 936 bytes/record
# From src/server/shared/DataStores/DBCStructure.h
# ---------------------------------------------------------------------------
$F_ID                   =   0
$F_DISPEL               =   2
$F_TARGETS              =  16
$F_CASTING_TIME_INDEX   =  28
$F_INTERRUPT_FLAGS      =  31
$F_AURA_INTERRUPT_FLAGS =  32
$F_DURATION_INDEX       =  40
$F_POWER_TYPE           =  41
$F_MANA_COST            =  42
$F_RANGE_INDEX          =  46
$F_EQUIPPED_ITEM_CLASS  =  68
$F_EFFECT_0             =  71
$F_EFFECT_1             =  72
$F_EFFECT_2             =  73
$F_EFFECT_BASE_PTS_0    =  80
$F_EFFECT_TARGET_A_0    =  86
$F_EFFECT_TARGET_A_1    =  87
$F_EFFECT_TARGET_A_2    =  88
$F_EFFECT_AURA_NAME_0   =  95
$F_EFFECT_AMPLITUDE_0   =  98
$F_EFF_DMG_MULT_0       = 216
$F_EFF_DMG_MULT_1       = 217
$F_EFF_DMG_MULT_2       = 218
$F_SPELL_ICON_ID        = 133
$F_ACTIVE_ICON_ID       = 134
$F_SPELL_NAME_0         = 136
$F_SPELL_NAME_FLAG      = 152
$F_RANK_FLAG            = 169
$F_DESC_0               = 170
$F_DESC_FLAG            = 186
$F_TOOLTIP_0            = 187
$F_TOOLTIP_FLAG         = 203
$F_MANA_COST_PCT        = 204
$F_START_RECOVERY_CAT   = 205
$F_START_RECOVERY_TIME  = 206
$F_SPELL_FAMILY_NAME    = 208
$F_FAMILY_FLAGS_0       = 209
$F_FAMILY_FLAGS_1       = 210
$F_FAMILY_FLAGS_2       = 211
$F_MAX_AFFECTED_TARGETS = 212
$F_DMG_CLASS            = 213
$F_PREVENTION_TYPE      = 214
$F_SCHOOL_MASK          = 225
$F_EFF_BONUS_MULT_0     = 229
$F_EFF_BONUS_MULT_1     = 230
$F_EFF_BONUS_MULT_2     = 231

# ---------------------------------------------------------------------------
# DBC helpers
# ---------------------------------------------------------------------------
function SetU32([byte[]]$rec, [int]$f, [uint32]$v) {
    [BitConverter]::GetBytes($v).CopyTo($rec, $f * 4)
}
function SetI32([byte[]]$rec, [int]$f, [int]$v) {
    [BitConverter]::GetBytes([int]$v).CopyTo($rec, $f * 4)
}
function SetF32([byte[]]$rec, [int]$f, [float]$v) {
    [BitConverter]::GetBytes([float]$v).CopyTo($rec, $f * 4)
}
function GetU32([byte[]]$a, [int]$off) {
    return [BitConverter]::ToUInt32($a, $off)
}

function CombineBytes([byte[]]$a, [byte[]]$b) {
    $r = New-Object byte[] ($a.Length + $b.Length)
    [Array]::Copy($a, 0, $r, 0, $a.Length)
    [Array]::Copy($b, 0, $r, $a.Length, $b.Length)
    return $r
}

# ---------------------------------------------------------------------------
# Step 1  -  Read and patch Spell.dbc
# ---------------------------------------------------------------------------
Write-Host "=== Step 1: Patching Spell.dbc ==="

if (-not (Test-Path $ServerDbcPath)) { throw "Server Spell.dbc not found: $ServerDbcPath" }
$raw         = [System.IO.File]::ReadAllBytes($ServerDbcPath)
$magic       = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
$recordCount = GetU32 $raw 4
$fieldCount  = GetU32 $raw 8
$recordSize  = GetU32 $raw 12
$strBlockSz  = GetU32 $raw 16

if ($magic      -ne "WDBC") { throw "Bad DBC magic: $magic" }
if ($fieldCount -ne 234)    { throw "Unexpected field count $fieldCount (expected 234)" }
if ($recordSize -ne 936)    { throw "Unexpected record size $recordSize (expected 936)" }

Write-Host "  Source: $recordCount records, ${fieldCount} fields, ${recordSize} bytes/rec"

$HEADER_SIZE   = 20
$strBlockStart = $HEADER_SIZE + [int]$recordCount * [int]$recordSize

# Scan for existing spell 600002
$TARGET_ID    = [uint32]600002
$existingOff  = -1
for ($i = 0; $i -lt [int]$recordCount; $i++) {
    $off = $HEADER_SIZE + $i * [int]$recordSize
    if ((GetU32 $raw $off) -eq $TARGET_ID) {
        $existingOff = $off
        Write-Host "  Spell $TARGET_ID found at record $i  -  will replace in-place."
        break
    }
}

# Expand string block with our strings appended at the end
$strBytes = New-Object byte[] $strBlockSz
[Array]::Copy($raw, $strBlockStart, $strBytes, 0, [int]$strBlockSz)
if ($strBytes[0] -ne 0) { throw "String block must begin with null terminator" }

$strList = [System.Collections.Generic.List[byte]]::new($strBytes)
function AppendStr([System.Collections.Generic.List[byte]]$lst, [string]$s) {
    $off = $lst.Count
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($s)) { $lst.Add($b) }
    $lst.Add([byte]0)
    return [int]$off
}

$nameOff    = AppendStr $strList "Celestial Resonance"
$descOff    = AppendStr $strList "Applies Celestial Resonance to the target. Holy Nova radiates from their position each second for 8 sec."
$tooltipOff = AppendStr $strList "Radiating Holy Nova once per second."

$newStrBlock   = $strList.ToArray()
$newStrBlockSz = [uint32]$newStrBlock.Length

# Build 936-byte spell record (zeroed, then fill required fields)
$rec = New-Object byte[] 936
SetU32 $rec $F_ID                   $TARGET_ID
SetU32 $rec $F_DISPEL               1               # DISPEL_MAGIC
SetU32 $rec $F_TARGETS              2               # TARGET_FLAG_UNIT
SetU32 $rec $F_CASTING_TIME_INDEX   16              # 1500 ms
SetU32 $rec $F_INTERRUPT_FLAGS      15              # 0xF: interrupted by movement/damage
SetU32 $rec $F_DURATION_INDEX       31              # 8000 ms
SetU32 $rec $F_POWER_TYPE           0               # mana
SetU32 $rec $F_RANGE_INDEX          5               # 40 yards
SetI32 $rec $F_EQUIPPED_ITEM_CLASS  -1              # no item required
SetU32 $rec $F_EFFECT_0             6               # SPELL_EFFECT_APPLY_AURA
SetU32 $rec $F_EFFECT_TARGET_A_0    25              # TARGET_UNIT_TARGET_ANY
SetU32 $rec $F_EFFECT_AURA_NAME_0   226             # SPELL_AURA_PERIODIC_DUMMY
SetU32 $rec $F_EFFECT_AMPLITUDE_0   1000            # tick every 1000 ms
SetF32 $rec $F_EFF_DMG_MULT_0       1.0             # must be 1.0, not 0
SetF32 $rec $F_EFF_DMG_MULT_1       1.0
SetF32 $rec $F_EFF_DMG_MULT_2       1.0
SetF32 $rec $F_EFF_BONUS_MULT_0     1.0
SetF32 $rec $F_EFF_BONUS_MULT_1     1.0
SetF32 $rec $F_EFF_BONUS_MULT_2     1.0
SetU32 $rec $F_SPELL_ICON_ID        1874            # Holy Nova icon
SetU32 $rec $F_ACTIVE_ICON_ID       1874
SetU32 $rec $F_SPELL_NAME_0         ([uint32]$nameOff)
SetU32 $rec $F_SPELL_NAME_FLAG      1               # bit 0 = enUS available
SetU32 $rec $F_DESC_0               ([uint32]$descOff)
SetU32 $rec $F_DESC_FLAG            1
SetU32 $rec $F_TOOLTIP_0            ([uint32]$tooltipOff)
SetU32 $rec $F_TOOLTIP_FLAG         1
SetU32 $rec $F_START_RECOVERY_CAT   133             # standard GCD category
SetU32 $rec $F_START_RECOVERY_TIME  1500            # 1500 ms GCD
SetU32 $rec $F_SPELL_FAMILY_NAME    6               # SPELLFAMILY_PRIEST
SetU32 $rec $F_DMG_CLASS            2               # SPELL_DAMAGE_CLASS_MAGIC
SetU32 $rec $F_PREVENTION_TYPE      1               # SPELL_PREVENTION_TYPE_SILENCE
SetU32 $rec $F_SCHOOL_MASK          2               # SPELL_SCHOOL_MASK_HOLY

# Assemble patched DBC
if ($existingOff -ge 0) {
    $allData = New-Object byte[] $raw.Length
    [Array]::Copy($raw, $allData, $raw.Length)
    $rec.CopyTo($allData, $existingOff)
    [BitConverter]::GetBytes($newStrBlockSz).CopyTo($allData, 16)
    $recsEndOff  = $HEADER_SIZE + [int]$recordCount * [int]$recordSize
    $hdrAndRecs  = New-Object byte[] $recsEndOff
    [Array]::Copy($allData, 0, $hdrAndRecs, 0, $recsEndOff)
    $dbcBytes = CombineBytes $hdrAndRecs $newStrBlock
    Write-Host "  Replaced existing record for spell $TARGET_ID."
} else {
    $newRecCount = [uint32]($recordCount + 1)
    $hdr = New-Object byte[] $HEADER_SIZE
    [System.Text.Encoding]::ASCII.GetBytes("WDBC").CopyTo($hdr, 0)
    [BitConverter]::GetBytes($newRecCount).CopyTo($hdr, 4)
    [BitConverter]::GetBytes($fieldCount).CopyTo($hdr, 8)
    [BitConverter]::GetBytes($recordSize).CopyTo($hdr, 12)
    [BitConverter]::GetBytes($newStrBlockSz).CopyTo($hdr, 16)
    $origLen   = [int]$recordCount * [int]$recordSize
    $origRecs  = New-Object byte[] $origLen
    [Array]::Copy($raw, $HEADER_SIZE, $origRecs, 0, $origLen)
    $dbcBytes = CombineBytes (CombineBytes (CombineBytes $hdr $origRecs) $rec) $newStrBlock
    Write-Host "  Appended new record for spell $TARGET_ID (total: $newRecCount records)."
}

Write-Host "  Patched DBC size: $($dbcBytes.Length) bytes"

# ---------------------------------------------------------------------------
# Step 2  -  Build crypt table (MPQ v1 prerequisite)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 2: Building MPQ ==="

# All arithmetic uses [long] (int64) to avoid PowerShell 5.1 uint32 overflow.
# Results are masked with 0xFFFFFFFFL after each operation to stay in 32-bit range.
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

# Verify against well-known constants.
# 0xC3AF3770 / 0xEC83B3A3 have bit 31 set, so PS 5.1 parses them as negative int32.
# Cast via long with mask to get the correct unsigned 32-bit positive value as [long].
$htKeyCheck = [long]([int]0xC3AF3770) -band 0xFFFFFFFFL   # 3283214192
$btKeyCheck = [long]([int]0xEC83B3A3) -band 0xFFFFFFFFL   # 3967029155

function MpqHash([string]$name, [int]$hashType) {
    $s1 = [long]0x7FED7FED
    $s2 = [long]0xEEEEEEEE
    foreach ($c in $name.ToUpper().ToCharArray()) {
        $ch = [int][char]$c
        $entry = $CryptTable[$hashType * 256 + $ch]
        $s1 = ($entry -bxor (($s1 + $s2) -band 0xFFFFFFFFL)) -band 0xFFFFFFFFL
        $s2 = ($ch + $s1 + $s2 + ($s2 -shl 5) + 3) -band 0xFFFFFFFFL
    }
    return $s1 -band 0xFFFFFFFFL
}

$htKeyActual = MpqHash "(hash table)"  3
$btKeyActual = MpqHash "(block table)" 3

if ([uint32]$htKeyActual -ne $htKeyCheck) {
    throw "Crypt table self-test FAILED: HT key expected 0x$($htKeyCheck.ToString('X8')), got 0x$(([uint32]$htKeyActual).ToString('X8'))"
}
if ([uint32]$btKeyActual -ne $btKeyCheck) {
    throw "Crypt table self-test FAILED: BT key expected 0x$($btKeyCheck.ToString('X8')), got 0x$(([uint32]$btKeyActual).ToString('X8'))"
}
Write-Host "  Crypt table self-test passed."

function MpqEncrypt([byte[]]$data, [int]$startByte, [int]$dwordCount, [long]$key) {
    $seed = [long]0xEEEEEEEE
    $k    = $key -band 0xFFFFFFFFL
    for ($i = 0; $i -lt $dwordCount; $i++) {
        $byteOff = $startByte + $i * 4
        $val  = [long][BitConverter]::ToUInt32($data, $byteOff)
        $seed = ($seed + $CryptTable[0x400 + ($k -band 0xFFL)]) -band 0xFFFFFFFFL
        $enc  = ($val -bxor (($k + $seed) -band 0xFFFFFFFFL)) -band 0xFFFFFFFFL
        # key = ((~key << 21) + 0x11111111) | (key >> 11)    -  all 32-bit
        $k    = ((( (-bnot $k) -band 0xFFFFFFFFL) -shl 21) + 0x11111111L) -bor ($k -shr 11)
        $k    = $k -band 0xFFFFFFFFL
        $seed = ($val + $seed + ($seed -shl 5) + 3) -band 0xFFFFFFFFL
        [BitConverter]::GetBytes([uint32]$enc).CopyTo($data, $byteOff)
    }
}

# ---------------------------------------------------------------------------
# Compute hashes for the DBC internal path
# ---------------------------------------------------------------------------
$hashOffset = MpqHash $InternalPath 0   # slot selector
$hashNameA  = MpqHash $InternalPath 1   # stored in hash table Name1
$hashNameB  = MpqHash $InternalPath 2   # stored in hash table Name2

# ---------------------------------------------------------------------------
# Step 1b  -  Patch SkillLineAbility.dbc (adds spell to Priest Holy spellbook tab)
# ---------------------------------------------------------------------------
$SlaDbcPath = "E:\servers\Wow\Standard\bin\data\dbc\SkillLineAbility.dbc"
if (-not (Test-Path $SlaDbcPath)) { throw "Not found: $SlaDbcPath" }
$slaRaw      = [System.IO.File]::ReadAllBytes($SlaDbcPath)
$slaMagic    = [System.Text.Encoding]::ASCII.GetString($slaRaw, 0, 4)
$slaRecCount = GetU32 $slaRaw 4
$slaFldCount = GetU32 $slaRaw 8
$slaRecSize  = GetU32 $slaRaw 12   # 56 bytes = 14 fields

if ($slaMagic -ne "WDBC") { throw "Bad SkillLineAbility.dbc magic: $slaMagic" }

Write-Host "  SkillLineAbility.dbc: $slaRecCount records, $slaFldCount fields"

# Skill line 594 = Priest Holy talent tree (verified from binary DBC)
$SLA_SKILL_PRIEST_HOLY = [uint32]594
$SLA_ENTRY_ID          = [uint32]50000   # unique ID above existing max (~21000)

# Check if our entry already exists
$slaExistingOff = -1
for ($i = 0; $i -lt [int]$slaRecCount; $i++) {
    $off = 20 + $i * [int]$slaRecSize
    if ((GetU32 $slaRaw $off) -eq $SLA_ENTRY_ID) {
        $slaExistingOff = $off
        Write-Host "  SLA entry $SLA_ENTRY_ID already exists at record $i  -  replacing."
        break
    }
}

# Build 56-byte (14 field) SkillLineAbility record
$slaRec = New-Object byte[] ([int]$slaRecSize)
[BitConverter]::GetBytes($SLA_ENTRY_ID).CopyTo($slaRec, 0)           # field 0: ID
[BitConverter]::GetBytes($SLA_SKILL_PRIEST_HOLY).CopyTo($slaRec, 4)  # field 1: SkillLine = 594
[BitConverter]::GetBytes($TARGET_ID).CopyTo($slaRec, 8)              # field 2: Spell = 600002
# All other fields (RaceMask, ClassMask, ExcludeRace, ExcludeClass,
# MinSkillLineRank, SupercededBySpell, AcquireMethod, Trivial*, CharPoints) = 0

if ($slaExistingOff -ge 0) {
    $slaBytes = New-Object byte[] $slaRaw.Length
    [Array]::Copy($slaRaw, $slaBytes, $slaRaw.Length)
    $slaRec.CopyTo($slaBytes, $slaExistingOff)
    Write-Host "  Updated existing SLA entry."
} else {
    $newSlaCount = [uint32]($slaRecCount + 1)
    $slaHdr = New-Object byte[] 20
    [System.Text.Encoding]::ASCII.GetBytes("WDBC").CopyTo($slaHdr, 0)
    [BitConverter]::GetBytes($newSlaCount).CopyTo($slaHdr, 4)
    [BitConverter]::GetBytes($slaFldCount).CopyTo($slaHdr, 8)
    [BitConverter]::GetBytes($slaRecSize).CopyTo($slaHdr, 12)
    [BitConverter]::GetBytes([uint32]0).CopyTo($slaHdr, 16)   # no string block
    $slaOrigLen  = [int]$slaRecCount * [int]$slaRecSize
    $slaOrigData = New-Object byte[] $slaOrigLen
    [Array]::Copy($slaRaw, 20, $slaOrigData, 0, $slaOrigLen)
    $slaBytes = CombineBytes (CombineBytes $slaHdr $slaOrigData) $slaRec
    Write-Host "  Appended SLA entry $SLA_ENTRY_ID (spell=$TARGET_ID, skillLine=$SLA_SKILL_PRIEST_HOLY)."
}
Write-Host "  SkillLineAbility.dbc size: $($slaBytes.Length) bytes"

# ---------------------------------------------------------------------------
# Step 2  -  Build crypt table (MPQ v1 prerequisite)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 2: Building MPQ ==="

# All arithmetic uses [long] (int64) to avoid PowerShell 5.1 uint32 overflow.
# Results are masked with 0xFFFFFFFFL after each operation to stay in 32-bit range.
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

# Verify against well-known constants (use uint32 to avoid sign-extension of hex literals)
$htKeyCheck = [uint32]([long]([int]0xC3AF3770) -band 0xFFFFFFFFL)   # 3283214192
$btKeyCheck = [uint32]([long]([int]0xEC83B3A3) -band 0xFFFFFFFFL)   # 3967029155

function MpqHash([string]$name, [int]$hashType) {
    $s1 = [long]0x7FED7FED
    $s2 = [long]0xEEEEEEEE
    foreach ($c in $name.ToUpper().ToCharArray()) {
        $ch = [int][char]$c
        $entry = $CryptTable[$hashType * 256 + $ch]
        $s1 = ($entry -bxor (($s1 + $s2) -band 0xFFFFFFFFL)) -band 0xFFFFFFFFL
        $s2 = ($ch + $s1 + $s2 + ($s2 -shl 5) + 3) -band 0xFFFFFFFFL
    }
    return $s1 -band 0xFFFFFFFFL
}

$htKeyActual = MpqHash "(hash table)"  3
$btKeyActual = MpqHash "(block table)" 3

if ([uint32]$htKeyActual -ne $htKeyCheck) {
    throw "Crypt table self-test FAILED: HT key expected 0x$($htKeyCheck.ToString('X8')), got 0x$(([uint32]$htKeyActual).ToString('X8'))"
}
if ([uint32]$btKeyActual -ne $btKeyCheck) {
    throw "Crypt table self-test FAILED: BT key expected 0x$($btKeyCheck.ToString('X8')), got 0x$(([uint32]$btKeyActual).ToString('X8'))"
}
Write-Host "  Crypt table self-test passed."

function MpqEncrypt([byte[]]$data, [int]$startByte, [int]$dwordCount, [long]$key) {
    $seed = [long]0xEEEEEEEE
    $k    = $key -band 0xFFFFFFFFL
    for ($i = 0; $i -lt $dwordCount; $i++) {
        $byteOff = $startByte + $i * 4
        $val  = [long][BitConverter]::ToUInt32($data, $byteOff)
        $seed = ($seed + $CryptTable[0x400 + ($k -band 0xFFL)]) -band 0xFFFFFFFFL
        $enc  = ($val -bxor (($k + $seed) -band 0xFFFFFFFFL)) -band 0xFFFFFFFFL
        # key = ((~key << 21) + 0x11111111) | (key >> 11)   -- all 32-bit
        $k    = ((( (-bnot $k) -band 0xFFFFFFFFL) -shl 21) + 0x11111111L) -bor ($k -shr 11)
        $k    = $k -band 0xFFFFFFFFL
        $seed = ($val + $seed + ($seed -shl 5) + 3) -band 0xFFFFFFFFL
        [BitConverter]::GetBytes([uint32]$enc).CopyTo($data, $byteOff)
    }
}

# ---------------------------------------------------------------------------
# Compute file hashes for both DBC files
# ---------------------------------------------------------------------------
$SlaInternalPath = "DBFilesClient\SkillLineAbility.dbc"

$hashOffset    = MpqHash $InternalPath    0
$hashNameA     = MpqHash $InternalPath    1
$hashNameB     = MpqHash $InternalPath    2
$slaHashOffset = MpqHash $SlaInternalPath 0
$slaHashNameA  = MpqHash $SlaInternalPath 1
$slaHashNameB  = MpqHash $SlaInternalPath 2

# Use 32 slots to guarantee no slot collision with 2 files
$HT_SIZE  = 32
$fileSlot    = [int]($hashOffset    % $HT_SIZE)
$slaFileSlot = [int]($slaHashOffset % $HT_SIZE)
Write-Host "  Spell.dbc slot: $fileSlot  SkillLineAbility.dbc slot: $slaFileSlot  (of $HT_SIZE)"
if ($fileSlot -eq $slaFileSlot) { throw "Hash table slot collision! Increase HT_SIZE." }

# ---------------------------------------------------------------------------
# Layout (two files, then hash table, then block table)
#   Offset 0                       : MPQ header (32 bytes)
#   Offset 32                      : Spell.dbc (file 0)
#   Offset 32 + spell_len          : SkillLineAbility.dbc (file 1)
#   Offset 32 + spell_len + sla_len: Hash table (32 x 16 = 512 bytes)
#   After hash table               : Block table (2 x 16 = 32 bytes)
# ---------------------------------------------------------------------------
$FILE1_OFF      = [int]32
$file1Len       = [int]$dbcBytes.Length
$FILE2_OFF      = $FILE1_OFF + $file1Len
$file2Len       = [int]$slaBytes.Length
$htOffLong      = [long]($FILE2_OFF + $file2Len)
$btOffLong      = $htOffLong + $HT_SIZE * 16
$archiveSizeLng = $btOffLong + 2 * 16

Write-Host "  Spell.dbc: offset=$FILE1_OFF size=$file1Len"
Write-Host "  SkillLineAbility.dbc: offset=$FILE2_OFF size=$file2Len"
Write-Host "  Hash table: offset=$htOffLong  Block table: offset=$btOffLong"
Write-Host "  Archive size: $archiveSizeLng bytes"

# ---------------------------------------------------------------------------
# Build hash table (512 bytes, all slots FREE, then fill our two entries)
# ---------------------------------------------------------------------------
$htBytes = New-Object byte[] ($HT_SIZE * 16)
for ($i = 0; $i -lt $HT_SIZE; $i++) {
    [BitConverter]::GetBytes([int]-1).CopyTo($htBytes, $i * 16 + 12)   # blockIndex = FREE
}

# Spell.dbc entry  -> block index 0
$so0 = $fileSlot * 16
[BitConverter]::GetBytes([uint32]$hashNameA).CopyTo($htBytes, $so0 + 0)
[BitConverter]::GetBytes([uint32]$hashNameB).CopyTo($htBytes, $so0 + 4)
[BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so0 + 8)    # locale
[BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so0 + 10)   # platform
[BitConverter]::GetBytes([uint32]0).CopyTo($htBytes, $so0 + 12)   # block index 0

# SkillLineAbility.dbc entry  -> block index 1
$so1 = $slaFileSlot * 16
[BitConverter]::GetBytes([uint32]$slaHashNameA).CopyTo($htBytes, $so1 + 0)
[BitConverter]::GetBytes([uint32]$slaHashNameB).CopyTo($htBytes, $so1 + 4)
[BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so1 + 8)
[BitConverter]::GetBytes([uint16]0).CopyTo($htBytes, $so1 + 10)
[BitConverter]::GetBytes([uint32]1).CopyTo($htBytes, $so1 + 12)   # block index 1

MpqEncrypt $htBytes 0 ($HT_SIZE * 4) $htKeyActual

# ---------------------------------------------------------------------------
# Build block table (2 entries x 16 bytes)
# ---------------------------------------------------------------------------
$MPQ_FILE_EXISTS = [int][System.Convert]::ToInt32("80000000", 16)
$btBytes = New-Object byte[] 32
# Entry 0: Spell.dbc
[BitConverter]::GetBytes([uint32]$FILE1_OFF).CopyTo($btBytes, 0)
[BitConverter]::GetBytes([uint32]$file1Len).CopyTo($btBytes, 4)
[BitConverter]::GetBytes([uint32]$file1Len).CopyTo($btBytes, 8)
[BitConverter]::GetBytes($MPQ_FILE_EXISTS).CopyTo($btBytes, 12)
# Entry 1: SkillLineAbility.dbc
[BitConverter]::GetBytes([uint32]$FILE2_OFF).CopyTo($btBytes, 16)
[BitConverter]::GetBytes([uint32]$file2Len).CopyTo($btBytes, 20)
[BitConverter]::GetBytes([uint32]$file2Len).CopyTo($btBytes, 24)
[BitConverter]::GetBytes($MPQ_FILE_EXISTS).CopyTo($btBytes, 28)

MpqEncrypt $btBytes 0 8 $btKeyActual   # 2 entries x 4 dwords = 8 dwords

# ---------------------------------------------------------------------------
# Build MPQ header (32 bytes)
# ---------------------------------------------------------------------------
$mpqHdr = New-Object byte[] 32
[System.Text.Encoding]::ASCII.GetBytes("MPQ").CopyTo($mpqHdr, 0)
$mpqHdr[3] = 0x1A
[BitConverter]::GetBytes([uint32]32).CopyTo($mpqHdr, 4)
[BitConverter]::GetBytes([uint32]$archiveSizeLng).CopyTo($mpqHdr, 8)
[BitConverter]::GetBytes([uint16]0).CopyTo($mpqHdr, 12)    # format version 0
[BitConverter]::GetBytes([uint16]3).CopyTo($mpqHdr, 14)    # block size shift
[BitConverter]::GetBytes([uint32]$htOffLong).CopyTo($mpqHdr, 16)
[BitConverter]::GetBytes([uint32]$btOffLong).CopyTo($mpqHdr, 20)
[BitConverter]::GetBytes([uint32]$HT_SIZE).CopyTo($mpqHdr, 24)
[BitConverter]::GetBytes([uint32]2).CopyTo($mpqHdr, 28)    # 2 block table entries

# ---------------------------------------------------------------------------
# Assemble final MPQ bytes
# ---------------------------------------------------------------------------
$mpqBytes = New-Object byte[] $archiveSizeLng
[Array]::Copy($mpqHdr,  0, $mpqBytes, 0,           32)
[Array]::Copy($dbcBytes, 0, $mpqBytes, $FILE1_OFF,  $file1Len)
[Array]::Copy($slaBytes, 0, $mpqBytes, $FILE2_OFF,  $file2Len)
[Array]::Copy($htBytes,  0, $mpqBytes, [int]$htOffLong, $htBytes.Length)
[Array]::Copy($btBytes,  0, $mpqBytes, [int]$btOffLong, $btBytes.Length)

# ---------------------------------------------------------------------------
# Step 3  -  Write outputs
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Step 3: Writing MPQ files ==="

[System.IO.File]::WriteAllBytes($OutMainMpq, $mpqBytes)
Write-Host "  Written: $OutMainMpq"

[System.IO.File]::WriteAllBytes($OutLocaleMpq, $mpqBytes)
Write-Host "  Written: $OutLocaleMpq"

Write-Host ""
Write-Host "Done. Restart the WoW client. Spell 600002 (Celestial Resonance) will appear"
Write-Host "in the Holy spellbook tab when the item imprint is equipped."
