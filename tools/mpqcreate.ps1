# mpqcreate.ps1
# Creates a minimal WoW-compatible MPQ v1 archive containing a single
# uncompressed file.  Works for any DBC or data file.
#
# Usage:
#   .\mpqcreate.ps1 -SourceFile <path> -InternalPath <DBFilesClient\Foo.dbc> -OutputMpq <path>
#
# WoW 3.3.5a client reads MPQ v1 archives.  This script:
#   1. Stores the file as a single uncompressed unit (no sector offsets).
#   2. Uses the standard MPQ Jenkins hash + encryption for the hash/block tables.
#   3. Sets a hash table of 16 slots (minimum useful prime for lookup).

param(
    [string]$SourceFile,
    [string]$InternalPath,
    [string]$OutputMpq
)

if (!$SourceFile -or !$InternalPath -or !$OutputMpq) {
    Write-Host "Usage: mpqcreate.ps1 -SourceFile <path> -InternalPath <DBFilesClient\Foo.dbc> -OutputMpq <path>"
    exit 1
}

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Inline C# -- MPQ v1 creator
# ---------------------------------------------------------------------------
Add-Type -Language CSharp @"
using System;
using System.IO;
using System.Text;

public static class MpqCreator
{
    // Standard MPQ crypt table (1280 uint32s)
    static readonly uint[] sTable = BuildTable();
    static uint[] BuildTable()
    {
        var t = new uint[0x500];
        uint seed = 0x00100001u;
        for (int i = 0; i < 0x100; i++)
        {
            int idx = i;
            for (int j = 0; j < 5; j++)
            {
                seed = (seed * 125 + 3) % 0x2AAAAB;
                uint hi = (seed & 0xFFFF) << 16;
                seed = (seed * 125 + 3) % 0x2AAAAB;
                uint lo = seed & 0xFFFF;
                t[idx] = hi | lo;
                idx += 0x100;
            }
        }
        return t;
    }

    // Hash a filename with a given hash type (0=table, 1=A, 2=B, 3=key)
    public static uint Hash(string s, uint type)
    {
        uint s1 = 0x7FED7FEDu, s2 = 0xEEEEEEEEu;
        foreach (char raw in s)
        {
            char c = (raw == '/') ? '\\' : char.ToUpper(raw);
            uint v = sTable[(type << 8) + c];
            s1 = v ^ (s1 + s2);
            s2 = c + s1 + s2 + (s2 << 5) + 3;
        }
        return s1;
    }

    // Encrypt a buffer in-place (must be multiple of 4 bytes)
    public static void Encrypt(byte[] buf, uint key)
    {
        uint s = 0xEEEEEEEEu;
        for (int i = 0; i < buf.Length / 4; i++)
        {
            s += sTable[0x400 + (key & 0xFF)];
            uint val = BitConverter.ToUInt32(buf, i * 4);
            val ^= key + s;
            Array.Copy(BitConverter.GetBytes(val), 0, buf, i * 4, 4);
            key = ((~key << 21) + 0x11111111u) | (key >> 11);
            s = val + s + (s << 5) + 3;
        }
    }

    public static void WriteUInt32(byte[] buf, int off, uint v)
    {
        var b = BitConverter.GetBytes(v);
        Array.Copy(b, 0, buf, off, 4);
    }
    public static void WriteUInt16(byte[] buf, int off, ushort v)
    {
        var b = BitConverter.GetBytes(v);
        Array.Copy(b, 0, buf, off, 2);
    }

    // Create a minimal MPQ containing one uncompressed file.
    // hashSlots must be a power of 2 (>= 16).
    public static void Create(string sourceFile, string internalPath, string outputMpq, int hashSlots = 16)
    {
        byte[] fileData = File.ReadAllBytes(sourceFile);
        uint fileSize = (uint)fileData.Length;

        // Layout:
        //   [0]       Header         32 bytes
        //   [32]      File data      fileSize bytes
        //   [32+fs]   Hash table     hashSlots * 16 bytes
        //   [32+fs+ht] Block table   16 bytes (1 entry)
        uint fileDataOff  = 32u;
        uint hashTableOff = fileDataOff + fileSize;
        uint blockTableOff= hashTableOff + (uint)(hashSlots * 16);
        uint archiveSize  = blockTableOff + 16u;

        // --- Header (32 bytes) ---
        byte[] hdr = new byte[32];
        hdr[0] = (byte)'M'; hdr[1] = (byte)'P'; hdr[2] = (byte)'Q'; hdr[3] = 0x1A;
        WriteUInt32(hdr,  4, 32u);             // header size
        WriteUInt32(hdr,  8, archiveSize);     // archive size
        WriteUInt16(hdr, 12, 0);               // format version 0
        WriteUInt16(hdr, 14, 3);               // block size shift (512 << 3 = 4096)
        WriteUInt32(hdr, 16, hashTableOff);
        WriteUInt32(hdr, 20, blockTableOff);
        WriteUInt32(hdr, 24, (uint)hashSlots);
        WriteUInt32(hdr, 28, 1u);              // 1 block entry

        // --- Block table (1 entry, 16 bytes) ---
        byte[] blockTable = new byte[16];
        WriteUInt32(blockTable,  0, fileDataOff);   // file offset
        WriteUInt32(blockTable,  4, fileSize);       // compressed size = uncompressed (no compression)
        WriteUInt32(blockTable,  8, fileSize);       // uncompressed size
        WriteUInt32(blockTable, 12, 0x81000000u);   // MPQ_FILE_EXISTS | MPQ_FILE_SINGLE_UNIT
        Encrypt(blockTable, Hash("(block table)", 3));

        // --- Hash table (hashSlots entries, each 16 bytes, all initially empty) ---
        byte[] hashTable = new byte[hashSlots * 16];
        // Fill unused entries with 0xFFFFFFFF (MPQ_HASH_ENTRY_FREE)
        for (int i = 0; i < hashSlots; i++)
        {
            WriteUInt32(hashTable, i * 16 + 0,  0xFFFFFFFFu);  // hash_a
            WriteUInt32(hashTable, i * 16 + 4,  0xFFFFFFFFu);  // hash_b
            WriteUInt32(hashTable, i * 16 + 8,  0xFFFFFFFFu);  // locale + platform (unused, set to 0xFF)
            WriteUInt32(hashTable, i * 16 + 12, 0xFFFFFFFFu);  // block_index (free)
        }

        // Insert our file into the hash table
        string upperPath = internalPath.Replace('/', '\\').ToUpper();
        uint hashStart = Hash(upperPath, 0) % (uint)hashSlots;
        uint hashA     = Hash(upperPath, 1);
        uint hashB     = Hash(upperPath, 2);

        // Linear probe to find free slot
        uint slot = hashStart;
        for (int attempt = 0; attempt < hashSlots; attempt++)
        {
            uint existing = BitConverter.ToUInt32(hashTable, (int)slot * 16 + 12);
            if (existing == 0xFFFFFFFF || existing == 0xFFFFFFFE)
            {
                WriteUInt32(hashTable, (int)slot * 16 + 0,  hashA);
                WriteUInt32(hashTable, (int)slot * 16 + 4,  hashB);
                WriteUInt16(hashTable, (int)slot * 16 + 8,  0);    // locale: neutral
                WriteUInt16(hashTable, (int)slot * 16 + 10, 0);    // platform: default
                WriteUInt32(hashTable, (int)slot * 16 + 12, 0u);   // block index 0
                break;
            }
            slot = (slot + 1) % (uint)hashSlots;
        }
        Encrypt(hashTable, Hash("(hash table)", 3));

        // --- Write archive ---
        using (var fs = new FileStream(outputMpq, FileMode.Create, FileAccess.Write))
        {
            fs.Write(hdr, 0, hdr.Length);
            fs.Write(fileData, 0, fileData.Length);
            fs.Write(hashTable, 0, hashTable.Length);
            fs.Write(blockTable, 0, blockTable.Length);
        }

        Console.WriteLine("Created: " + outputMpq);
        Console.WriteLine("  Internal path: " + internalPath);
        Console.WriteLine("  File size: " + fileSize + " bytes");
        Console.WriteLine("  Archive size: " + archiveSize + " bytes");
    }
}
"@

Write-Host "MPQ creator loaded. Creating archive..."
Write-Host "  Source:   $SourceFile"
Write-Host "  Internal: $InternalPath"
Write-Host "  Output:   $OutputMpq"

[MpqCreator]::Create($SourceFile, $InternalPath, $OutputMpq)
