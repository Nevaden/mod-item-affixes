# Client MPQ Patch — Running Record

Documents every DBC record we have injected into the WoW 3.3.5a client via `patch-z.MPQ`,
along with the complete technical reference for building and extending the patch in the future.

---

## Quick reference

| Item | Value |
|---|---|
| Script | `tools/patch_mpq_spells.ps1` |
| Client target | `E:\servers\Wow\WoW HD\data\patch-z.MPQ` |
| Locale target | `E:\servers\Wow\WoW HD\data\enus\patch-enUS-z.MPQ` (identical content) |
| DBC source | `E:\servers\Wow\Standard\bin\data\dbc\` (read-only reference) |
| MPQ format | v1 (WotLK client format) |
| Hash table slots | 32 (expand if collision occurs — see Gotchas) |

Run the script any time DBC data changes, then restart the WoW client:

```powershell
cd "E:\servers\Wow\Standard\azerothcore\modules\mod-item-affixes\tools"
powershell -ExecutionPolicy Bypass -File .\patch_custom_spells.ps1
```

The script is idempotent: it detects and replaces existing records by ID, then rebuilds both
MPQ files from scratch. Safe to re-run at any time.

---

## DBC records currently patched

### Spell.dbc

Internal MPQ path: `DBFilesClient\Spell.dbc`  
Source: server's Spell.dbc (49,840 records, 234 fields, 936 bytes/record)  
Operation: scan for existing record by ID; replace in-place if found, append if new.

| Spell ID | Name | Added | Purpose |
|---|---|---|---|
| 600002 | Celestial Resonance | 2026-05-23 | Priest Imprint: SPELL_AURA_PERIODIC_DUMMY, 8 s duration, 1 s tick, fires Holy Nova from target's position |

**Key fields for spell 600002:**

| DBC Field | Index | Value | Meaning |
|---|---|---|---|
| ID | 0 | 600002 | Unique spell ID |
| CastingTimeIndex | 28 | 16 | 1500 ms cast time |
| DurationIndex | 40 | 31 | 8000 ms duration |
| RangeIndex | 46 | 5 | 40 yards |
| EquippedItemClass | 68 | -1 | No item required (default 0 causes SPELL_FAILED_EQUIPPED_ITEM_CLASS) |
| Effect_0 | 71 | 6 | SPELL_EFFECT_APPLY_AURA |
| EffectAura_0 | 95 | 226 | SPELL_AURA_PERIODIC_DUMMY |
| EffectAuraPeriod_0 | 98 | 1000 | Tick every 1000 ms |
| ImplicitTargetA_0 | 86 | 25 | TARGET_UNIT_TARGET_ANY (ally + enemy) |
| SpellIconID | 133 | 1874 | Holy Nova icon |
| SpellName_0 | 136 | "Celestial Resonance" | enUS name (string block offset) |
| Description_0 | 170 | "Applies Celestial Resonance..." | enUS description |
| StartRecoveryCategory | 205 | 133 | Standard GCD category |
| StartRecoveryTime | 206 | 1500 | 1500 ms GCD |
| SpellFamilyName | 208 | 6 | SPELLFAMILY_PRIEST |
| SchoolMask | 225 | 2 | SPELL_SCHOOL_MASK_HOLY |

---

### SkillLineAbility.dbc

Internal MPQ path: `DBFilesClient\SkillLineAbility.dbc`  
Source: server's SkillLineAbility.dbc (10,219 records, 14 fields, 56 bytes/record)  
Operation: scan for existing record by ID; replace in-place if found, append if new.

| Entry ID | SkillLine | Spell ID | Added | Purpose |
|---|---|---|---|---|
| 50000 | 594 | 600002 | 2026-05-23 | Places Celestial Resonance in the Priest Holy spellbook tab |

**SkillLine IDs of interest (from binary SkillLine.dbc):**

| ID | Name | Notes |
|---|---|---|
| 594 | Holy | Priest Holy talent tree tab — use this for Holy spells |
| 613 | Discipline | Priest Discipline talent tree tab |
| 78 | Shadow Magic | Shadow tab |
| 56 | Holy | General magic school — appears in General tab, not class tabs |

> The DB tables `skilllineability_dbc` and `skillline_dbc` are EMPTY. All data comes from
> the binary DBC files. Parse them with PowerShell if you need index values (recipe below).

---

## Adding a new DBC record in the future

### For a new spell (Spell.dbc)

1. **Choose a free spell ID.** Custom spells use IDs starting at 600000. Check `spell_dbc` in
   the world DB and existing entries in `patch_mpq_spells.ps1` for what is already taken.

2. **Add a server-side `spell_dbc` row.** Create or extend a SQL file in
   `data/sql/db-world/`. The server entry controls gameplay; the client entry controls display.

3. **Add the record to `patch_mpq_spells.ps1`.** Extend Step 1 in the script:
   - Add new string literals to the string block (`AppendStr`)
   - Build a 936-byte record with `SetU32`/`SetI32`/`SetF32` helpers
   - Apply it with the same scan-and-replace or append logic

4. **Run the script and replace the client MPQ files.**

### For a new SkillLineAbility (spellbook tab placement)

Only needed when a spell is learned into the player's spellbook via `learnSpell`.

1. **Pick a free Entry ID** above 50000 (existing max is ~21000; our custom range starts at 50000).
2. **Identify the correct SkillLine ID** for the class/spec tab (see table above, or parse the binary).
3. **Add the entry in `patch_mpq_spells.ps1` Step 1b** alongside the existing entry for 600002.
4. **Re-run the script.**

### For a new DBC file entirely

1. Add a new path constant (e.g. `$NewDbcInternalPath = "DBFilesClient\NewFile.dbc"`).
2. Read and patch the source DBC (same WDBC parse pattern as existing steps).
3. Add hashes for the new internal path to the hash-computation block.
4. Check for slot collision and increase `$HT_SIZE` if needed (must be a power of 2).
5. Add the file to the layout: increment file count, adjust offsets, extend block table.

---

## How the script works

### DBC binary format (WDBC)

```
Header (20 bytes):
  [0]  char[4]  magic        "WDBC"
  [4]  uint32   recordCount
  [8]  uint32   fieldCount
  [12] uint32   recordSize   (fieldCount * 4)
  [16] uint32   stringBlockSize

Records (recordCount * recordSize bytes):
  Each record is recordSize bytes; fields are 4-byte little-endian integers/floats.
  String fields hold a byte offset into the string block (not the string itself).

String block (stringBlockSize bytes):
  Null-terminated ASCII strings. First byte is always 0x00 (empty string = offset 0).
```

To add a record: build a zeroed byte array of `recordSize` bytes, set required fields with
`SetU32`/`SetI32`/`SetF32`, append strings to the string block and store their offsets.

### MPQ v1 binary format

WotLK reads game data from `.mpq` archives loaded in alphabetical order by patch letter.
Higher letter = higher priority. `patch-z.MPQ` overrides everything including the flying mod's
`patch-y.MPQ`.

```
Layout:
  [0]        MPQ header (32 bytes)
  [32]       File data (files concatenated, uncompressed)
  [...]      Hash table  (HT_SIZE * 16 bytes, encrypted)
  [...]      Block table (fileCount * 16 bytes, encrypted)

MPQ header (32 bytes):
  [0]  char[3] + 0x1A  "MPQ\x1A"
  [4]  uint32  headerSize   32
  [8]  uint32  archiveSize
  [12] uint16  formatVersion  0 (v1)
  [14] uint16  blockSizeShift 3
  [16] uint32  hashTableOffset
  [20] uint32  blockTableOffset
  [24] uint32  hashTableSize  (slot count, power of 2)
  [28] uint32  blockTableEntries (file count)

Hash table slot (16 bytes per slot):
  [0]  uint32  Name1       (hash type 1 of filename)
  [4]  uint32  Name2       (hash type 2 of filename)
  [8]  uint16  Locale      0
  [10] uint16  Platform    0
  [12] uint32  BlockIndex  (index into block table; 0xFFFFFFFF = free slot)

Block table entry (16 bytes per file):
  [0]  uint32  FileOffset   (from start of archive)
  [4]  uint32  CompressedSize
  [8]  uint32  UncompressedSize
  [12] uint32  Flags        (0x80000000 = MPQ_FILE_EXISTS, uncompressed)
```

Files are stored uncompressed (Flags = 0x80000000, CompressedSize = UncompressedSize).

### Crypt table and encryption

The hash table and block table are XOR-encrypted. The crypt table is a 1280-entry lookup seeded
at `0x00100001`. Self-test constants (used to verify the table built correctly):

```
MpqHash("(hash table)",  3) == 0xC3AF3770   (hash table encryption key)
MpqHash("(block table)", 3) == 0xEC83B3A3   (block table encryption key)
```

Three hash types per filename:
- Type 0 → hash table slot (`fileOffset % HT_SIZE`)
- Type 1 → `Name1` stored in hash slot
- Type 2 → `Name2` stored in hash slot

---

## PowerShell 5.1 gotchas (critical — cost hours to debug)

### Hex literals > 0x7FFFFFFF are signed int32

PowerShell 5.1 parses `0xC3AF3770` as a negative `int32` (-1011753104). Casting that to
`[uint32]` throws `InvalidCastException`. Pattern to get the correct positive long value:

```powershell
# WRONG — throws InvalidCastException
[uint32]0xC3AF3770

# CORRECT — sign-extend to long then mask to 32 bits
[long]([int]0xC3AF3770) -band 0xFFFFFFFFL   # → 3283214192L (positive, correct)
```

Apply this everywhere a 32-bit constant has bit 31 set: `0xC3AF3770`, `0xEC83B3A3`,
`0x80000000` (MPQ_FILE_EXISTS), `0xFFFFFFFF` (free hash slot — use `[int]-1` instead).

For the free-slot sentinel: `[BitConverter]::GetBytes([int]-1)` produces `FF FF FF FF` correctly.

### All MPQ arithmetic must use `[long]` with `0xFFFFFFFFL` masks

Intermediate values overflow int32 silently. Every addition, XOR, shift, and multiply in the
crypt table build and encrypt function must be done in `[long]` with an `0xFFFFFFFFL` mask after
each operation:

```powershell
$s1 = ($entry -bxor (($s1 + $s2) -band 0xFFFFFFFFL)) -band 0xFFFFFFFFL
```

### UTF-8 em dash (—) and special characters corrupt the script

PowerShell 5.1 reads `.ps1` files as cp1252 by default. A UTF-8 em dash (bytes `E2 80 94`) is
read as three cp1252 characters; byte `0x94` is RIGHT DOUBLE QUOTATION MARK, which closes string
literals mid-expression. Symptom: cryptic parse error at an unrelated line.

Fix: use only ASCII characters in `.ps1` files. Replace `—` with ` - ` and `×` with `x`.
If the Write tool saves UTF-8 BOM, re-save as ASCII:

```powershell
$text = [System.IO.File]::ReadAllText("file.ps1", [System.Text.Encoding]::UTF8)
$text = $text -replace [char]0x2014, ' - '   # em dash
[System.IO.File]::WriteAllText("file.ps1", $text, [System.Text.Encoding]::ASCII)
```

### Comparison of `[uint32]` vs `[long]` crypt table values

After `MpqHash` returns a `[long]`, comparing it with `[uint32]` works correctly because
PowerShell widens the uint32 for comparison. But `[uint32]([long]0xC3AF3770)` will give the
wrong value because `[long]0xC3AF3770` is still negative (PS parses the literal as int32 first).
Always construct expected constants with the mask pattern:

```powershell
$expected = [uint32]([long]([int]0xC3AF3770) -band 0xFFFFFFFFL)
```

---

## Parsing binary DBC files from PowerShell

Use this recipe to inspect or look up values in any DBC file without a DBC editor:

```powershell
$raw = [System.IO.File]::ReadAllBytes("E:\servers\Wow\Standard\bin\data\dbc\SkillLine.dbc")
$recCount  = [BitConverter]::ToUInt32($raw, 4)
$fldCount  = [BitConverter]::ToUInt32($raw, 8)
$recSize   = [BitConverter]::ToUInt32($raw, 12)
$strBlkSz  = [BitConverter]::ToUInt32($raw, 16)
$strStart  = 20 + $recCount * $recSize

for ($i = 0; $i -lt [int]$recCount; $i++) {
    $base = 20 + $i * [int]$recSize
    $id   = [BitConverter]::ToUInt32($raw, $base)
    # Field 2 in SkillLine.dbc is a string offset (enUS name):
    $nameOff = [BitConverter]::ToUInt32($raw, $base + 2 * 4)
    $nameEnd = [Array]::IndexOf($raw, [byte]0, [int]($strStart + $nameOff))
    $name = [System.Text.Encoding]::UTF8.GetString($raw, [int]($strStart + $nameOff), $nameEnd - [int]($strStart + $nameOff))
    Write-Host "ID=$id  Name='$name'"
}
```

Adjust field offsets (multiply field index by 4) for whichever DBC you are reading.

---

## Known discoveries and reference values

| Discovery | Detail |
|---|---|
| flying mod uses `patch-y.MPQ` | Contains a DBC with 38 fields / 152 bytes per record — NOT Spell.dbc. Do not attempt to merge with it; create `patch-z.MPQ` as a separate higher-priority archive |
| SkillLine 594 = Priest Holy tree | Verified by parsing binary SkillLine.dbc. ID 56 = "Holy" (General magic school tab — wrong); 594 = "Holy" (Priest Holy talent tree tab — correct) |
| SkillLine DB tables are empty | `skilllineability_dbc` and `skillline_dbc` in the world DB have no rows. All data comes from binary DBC files in the shared data directory |
| Spell.dbc has 49,840 records | On this server installation. The script scans linearly for the target ID; on a complete client DBC the count will be different but the format is identical |
| Hash table slot collision | With 16 slots, `Spell.dbc` (slot 5) and `SkillLineAbility.dbc` collided. Expanded to 32 slots: Spell.dbc → slot 5, SkillLineAbility.dbc → slot 11. Always check for collision and increase `$HT_SIZE` (power of 2) if it occurs |
| `EquippedItemClass` default | A `spell_dbc` row that omits `EquippedItemClass` defaults to 0, which means "requires item of class 0 equipped" → `SPELL_FAILED_EQUIPPED_ITEM_CLASS` on every cast. Always set to -1 |
| `removeSpell` spec mask | `Player::removeSpell(uint32, uint8 removeSpecMask, bool onlyTemporary)`. Passing `false` for the second arg coerces to 0 = "remove from no specs" = silent no-op. Pass `SPEC_MASK_ALL` (255, defined in `Player.h`) |
| Locale MPQ path | The main `patch-z.MPQ` must also be copied to `data\enus\patch-enUS-z.MPQ`. WotLK loads both and the locale file takes precedence for text; having identical content in both is safe |
