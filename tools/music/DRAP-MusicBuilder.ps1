# DRAP Music Builder -- adds your own songs to Dead Rising for DRAP's Music Shuffle.
#
# Put songs in the two folders next to the game:
#   <game folder>\DRAP Music\Mall Music\     songs for the mall's PA speakers
#   <game folder>\DRAP Music\Action Music\   psychopath fights, story and event music
# then run "DRAP Music Builder.bat" with the game closed. "DRAP Music
# Uninstall.bat" removes everything it added.
#
# Your songs are ADDED to the game's music as new tracks. Nothing of the
# game's own music is changed or replaced, so the game sounds exactly as it
# always did -- until you connect to an Archipelago seed with Music Shuffle
# on, when DRAP points the game's music cues at your songs. Offline, or with
# Music Shuffle off, nothing ever asks for them.
#
# How: the game's music lives in Wwise files (BGM_m.bnk, BGM_e.bnk,
# BGM_m.pck) and an event list (BGM.wel) inside its .pak archives. This reads
# them, copies every original byte, appends one new Sound, play/stop event and
# trigger per song (cloned from the game's own), and writes the result to
# natives\, where REFramework's loose-file loader serves it. It checks that
# every original object is still byte-identical before writing anything.
#
# Needs ffmpeg (not included) to convert your songs.

param([switch]$Uninstall, [switch]$NoPause)

$ErrorActionPreference = "Stop"
$GameDir = $PSScriptRoot
$MusicDir = Join-Path $GameDir "DRAP Music"
$MallDir = Join-Path $MusicDir "Mall Music"
$ActionDir = Join-Path $MusicDir "Action Music"
$Manifest = Join-Path $MusicDir "installed.json"
$Settings = Join-Path $MusicDir "settings.json"
$LuaList = "reframework\data\DRAP_Music.json"
$AudioExt = @(".mp3", ".ogg", ".flac", ".wav", ".m4a", ".opus", ".wma", ".aac")
$SizeCap = 3.5GB

# Files written (relative to the game folder). The four loader suffixes are
# all written; one copy on disk, the others hard links.
$Suffixes = @("STM.En", "STM", "X64.En", "X64")
$PakNames = @{
    bnk_m = "natives/STM/Sound/Wwise/BGM_m.bnk.2.X64"
    bnk_e = "natives/STM/Sound/Wwise/BGM_e.bnk.2.X64"
    pck   = "natives/STM/streaming/Sound/Wwise/BGM_m.pck.3.X64"
    wel   = "natives/STM/Sound/Asset/BGM/EventList/BGM.wel.11"
}
$OutBase = @{
    bnk_m = "natives\STM\Sound\Wwise\BGM_m.bnk.2"
    bnk_e = "natives\STM\Sound\Wwise\BGM_e.bnk.2"
    stub  = "natives\STM\Sound\Wwise\BGM_m.pck.3"
    pck   = "natives\STM\streaming\Sound\Wwise\BGM_m.pck.3"
}
$OutWel = "natives\STM\Sound\Asset\BGM\EventList\BGM.wel.11"

# Everything printed also goes to "DRAP Music\Music Builder log.txt" once the
# folder exists, so a player can attach it to a bug report. (Our own log
# rather than Start-Transcript, which writes the PC and user name into it.)
$LogFile = $null
function Write-Host {
    param([Parameter(Position = 0)]$Object = "", $ForegroundColor)
    if ($ForegroundColor) { Microsoft.PowerShell.Utility\Write-Host $Object -ForegroundColor $ForegroundColor }
    else { Microsoft.PowerShell.Utility\Write-Host $Object }
    if ($LogFile) { Add-Content -Path $LogFile -Value "$Object" -Encoding UTF8 }
}

function Done($code) {
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to close"
    }
    exit $code
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class DrapMusic {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr sa);
    public static bool HardLink(string newPath, string existing) { return CreateHardLink(newPath, existing, IntPtr.Zero); }

    static uint Rotl(uint x, int r) { return (x << r) | (x >> (32 - r)); }

    public static uint Murmur3(byte[] data, uint seed) {
        unchecked {
            const uint c1 = 0xcc9e2d51, c2 = 0x1b873593;
            uint h = seed;
            int n = data.Length / 4;
            for (int i = 0; i < n; i++) {
                uint k = BitConverter.ToUInt32(data, i * 4);
                k *= c1; k = Rotl(k, 15); k *= c2;
                h ^= k; h = Rotl(h, 13); h = h * 5 + 0xe6546b64;
            }
            int rem = data.Length & 3;
            if (rem > 0) {
                uint t = 0;
                for (int i = rem - 1; i >= 0; i--) t = (t << 8) | data[n * 4 + i];
                t *= c1; t = Rotl(t, 15); t *= c2;
                h ^= t;
            }
            h ^= (uint)data.Length;
            h ^= h >> 16; h *= 0x85ebca6b; h ^= h >> 13; h *= 0xc2b2ae35; h ^= h >> 16;
            return h;
        }
    }

    // Wwise-style 32-bit FNV-1 of a lower-cased name: how new ids are made.
    public static uint Fnv1(string name) {
        unchecked {
            uint h = 2166136261;
            foreach (byte b in Encoding.UTF8.GetBytes(name.ToLowerInvariant())) { h *= 16777619; h ^= b; }
            return h;
        }
    }

    // One uncompressed file out of the first pak (in the order given) holding it.
    public static byte[] ReadFromPaks(string[] paks, string path) {
        uint lo = Murmur3(Encoding.Unicode.GetBytes(path.ToLowerInvariant()), 0xFFFFFFFF);
        uint up = Murmur3(Encoding.Unicode.GetBytes(path.ToUpperInvariant()), 0xFFFFFFFF);
        foreach (string pak in paks) {
            if (!File.Exists(pak)) continue;
            using (FileStream fs = new FileStream(pak, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                byte[] hdr = new byte[16];
                fs.Read(hdr, 0, 16);
                if (Encoding.ASCII.GetString(hdr, 0, 4) != "KPKA") throw new Exception(pak + " is not an RE Engine pak");
                if (BitConverter.ToUInt16(hdr, 6) != 0) throw new Exception(pak + " has an encrypted file table; this game version is not supported");
                int count = (int)BitConverter.ToUInt32(hdr, 8);
                byte[] toc = new byte[count * 48];
                int got = 0;
                while (got < toc.Length) got += fs.Read(toc, got, toc.Length - got);
                for (int i = 0; i < count; i++) {
                    int e = i * 48;
                    if (BitConverter.ToUInt32(toc, e) != lo || BitConverter.ToUInt32(toc, e + 4) != up) continue;
                    long off = BitConverter.ToInt64(toc, e + 8), csz = BitConverter.ToInt64(toc, e + 16);
                    long rsz = BitConverter.ToInt64(toc, e + 24), attr = BitConverter.ToInt64(toc, e + 32);
                    long kind = attr & 0xF;
                    if (kind > 1) throw new Exception(path + " uses an unsupported compression in " + pak + "; this game version is not supported");
                    byte[] data = new byte[csz];
                    fs.Seek(off, SeekOrigin.Begin);
                    int r = 0;
                    while (r < data.Length) { int k = fs.Read(data, r, data.Length - r); if (k <= 0) throw new Exception("short read in " + pak); r += k; }
                    if (kind == 0) return data;
                    // kind 1: raw deflate (the small sound files are stored this way)
                    byte[] outb = new byte[rsz];
                    using (System.IO.Compression.DeflateStream z = new System.IO.Compression.DeflateStream(new MemoryStream(data), System.IO.Compression.CompressionMode.Decompress)) {
                        int w = 0;
                        while (w < outb.Length) { int k = z.Read(outb, w, outb.Length - w); if (k <= 0) break; w += k; }
                        if (w != outb.Length) throw new Exception("could not unpack " + path);
                    }
                    return outb;
                }
            }
        }
        return null;
    }

    public static byte[] PcmWem(byte[] pcm, int rate, int ch) {
        uint chcfg = ch == 1 ? (0x4u << 12) | (1u << 8) | 1u : (0x3u << 12) | (1u << 8) | 2u;
        MemoryStream ms = new MemoryStream();
        BinaryWriter w = new BinaryWriter(ms);
        w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write((uint)(4 + 8 + 24 + 8 + pcm.Length));
        w.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write((uint)24);
        w.Write((ushort)0xFFFE); w.Write((ushort)ch); w.Write((uint)rate);
        w.Write((uint)(rate * 2 * ch)); w.Write((ushort)(2 * ch)); w.Write((ushort)16);
        w.Write((ushort)6); w.Write((ushort)0); w.Write(chcfg);
        w.Write(Encoding.ASCII.GetBytes("data")); w.Write((uint)pcm.Length); w.Write(pcm);
        w.Flush();
        return ms.ToArray();
    }

    // ---- bank sections -------------------------------------------------
    public class Section { public string Tag; public int Pos; public int Size; }

    public static List<Section> Sections(byte[] d) {
        List<Section> l = new List<Section>();
        int pos = 0;
        while (pos + 8 <= d.Length) {
            Section s = new Section();
            s.Tag = Encoding.ASCII.GetString(d, pos, 4); s.Pos = pos; s.Size = (int)BitConverter.ToUInt32(d, pos + 4);
            l.Add(s); pos += 8 + s.Size;
        }
        return l;
    }

    static Section Find(byte[] d, string tag) {
        foreach (Section s in Sections(d)) if (s.Tag == tag) return s;
        return null;
    }

    // HIRC objects: id -> whole object bytes (type, size, id, body).
    public static Dictionary<uint, byte[]> Hirc(byte[] d) {
        Dictionary<uint, byte[]> o = new Dictionary<uint, byte[]>();
        Section h = Find(d, "HIRC");
        int n = (int)BitConverter.ToUInt32(d, h.Pos + 8), p = h.Pos + 12;
        for (int i = 0; i < n; i++) {
            int sz = (int)BitConverter.ToUInt32(d, p + 1);
            uint id = BitConverter.ToUInt32(d, p + 5);
            byte[] obj = new byte[5 + sz];
            Buffer.BlockCopy(d, p, obj, 0, obj.Length);
            o[id] = obj;
            p += 5 + sz;
        }
        return o;
    }

    // Body (after type, size, id) of a vanilla object, as a fresh copy.
    public static byte[] Body(byte[] bnk, uint id) {
        byte[] obj;
        if (!Hirc(bnk).TryGetValue(id, out obj)) return null;
        byte[] b = new byte[obj.Length - 9];
        Buffer.BlockCopy(obj, 9, b, 0, b.Length);
        return b;
    }

    public static byte[] MakeObject(byte type, uint id, byte[] body) {
        byte[] o = new byte[9 + body.Length];
        o[0] = type;
        Buffer.BlockCopy(BitConverter.GetBytes((uint)(4 + body.Length)), 0, o, 1, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(id), 0, o, 5, 4);
        Buffer.BlockCopy(body, 0, o, 9, body.Length);
        return o;
    }

    // Appends objects at the end of HIRC; every other byte is copied.
    public static byte[] AppendHirc(byte[] d, List<byte[]> objs) {
        MemoryStream ms = new MemoryStream();
        int added = 0, count = 0;
        foreach (byte[] o in objs) { added += o.Length; count++; }
        foreach (Section s in Sections(d)) {
            if (s.Tag != "HIRC") { ms.Write(d, s.Pos, 8 + s.Size); continue; }
            ms.Write(Encoding.ASCII.GetBytes("HIRC"), 0, 4);
            ms.Write(BitConverter.GetBytes((uint)(s.Size + added)), 0, 4);
            ms.Write(BitConverter.GetBytes(BitConverter.ToUInt32(d, s.Pos + 8) + (uint)count), 0, 4);
            ms.Write(d, s.Pos + 12, s.Size - 4);
            foreach (byte[] o in objs) ms.Write(o, 0, o.Length);
        }
        return ms.ToArray();
    }

    // Media index: entries (id, offset, size) in id order; new data appended
    // 16-byte aligned at the end of DATA, so every vanilla offset holds.
    public static byte[] AddMedia(byte[] d, Dictionary<uint, byte[]> slices) {
        Section di = Find(d, "DIDX"), da = Find(d, "DATA");
        List<uint[]> entries = new List<uint[]>();
        for (int i = 0; i < di.Size / 12; i++)
            entries.Add(new uint[] { BitConverter.ToUInt32(d, di.Pos + 8 + i * 12), BitConverter.ToUInt32(d, di.Pos + 12 + i * 12), BitConverter.ToUInt32(d, di.Pos + 16 + i * 12) });
        MemoryStream data = new MemoryStream();
        data.Write(d, da.Pos + 8, da.Size);
        foreach (KeyValuePair<uint, byte[]> kv in slices) {
            while (data.Length % 16 != 0) data.WriteByte(0);
            entries.Add(new uint[] { kv.Key, (uint)data.Length, (uint)kv.Value.Length });
            data.Write(kv.Value, 0, kv.Value.Length);
        }
        entries.Sort(delegate(uint[] a, uint[] b) { return a[0].CompareTo(b[0]); });
        MemoryStream ms = new MemoryStream();
        foreach (Section s in Sections(d)) {
            if (s.Tag == "DIDX") {
                ms.Write(Encoding.ASCII.GetBytes("DIDX"), 0, 4); ms.Write(BitConverter.GetBytes((uint)(12 * entries.Count)), 0, 4);
                foreach (uint[] e in entries) { ms.Write(BitConverter.GetBytes(e[0]), 0, 4); ms.Write(BitConverter.GetBytes(e[1]), 0, 4); ms.Write(BitConverter.GetBytes(e[2]), 0, 4); }
            } else if (s.Tag == "DATA") {
                byte[] db = data.ToArray();
                ms.Write(Encoding.ASCII.GetBytes("DATA"), 0, 4); ms.Write(BitConverter.GetBytes((uint)db.Length), 0, 4); ms.Write(db, 0, db.Length);
            } else ms.Write(d, s.Pos, 8 + s.Size);
        }
        return ms.ToArray();
    }

    public static Dictionary<uint, byte[]> Media(byte[] d) {
        Dictionary<uint, byte[]> m = new Dictionary<uint, byte[]>();
        Section di = Find(d, "DIDX"), da = Find(d, "DATA");
        if (di == null) return m;
        for (int i = 0; i < di.Size / 12; i++) {
            uint id = BitConverter.ToUInt32(d, di.Pos + 8 + i * 12);
            int off = (int)BitConverter.ToUInt32(d, di.Pos + 12 + i * 12), sz = (int)BitConverter.ToUInt32(d, di.Pos + 16 + i * 12);
            byte[] b = new byte[sz];
            Buffer.BlockCopy(d, da.Pos + 8 + off, b, 0, sz);
            m[id] = b;
        }
        return m;
    }

    // ---- event list (.wel): 512-byte header, count @512, 62-byte records sorted by trigger
    public static List<byte[]> WelRecords(byte[] wel) {
        List<byte[]> l = new List<byte[]>();
        int n = (int)BitConverter.ToUInt32(wel, 512);
        for (int i = 0; i < n; i++) { byte[] r = new byte[62]; Buffer.BlockCopy(wel, 516 + i * 62, r, 0, 62); l.Add(r); }
        return l;
    }

    public static byte[] WelRecord(byte[] wel, uint trigger) {
        foreach (byte[] r in WelRecords(wel)) if (BitConverter.ToUInt32(r, 0) == trigger) return r;
        return null;
    }

    public static byte[] WelAdd(byte[] wel, List<byte[]> add) {
        List<byte[]> recs = WelRecords(wel);
        recs.AddRange(add);
        recs.Sort(delegate(byte[] a, byte[] b) { return BitConverter.ToUInt32(a, 0).CompareTo(BitConverter.ToUInt32(b, 0)); });
        MemoryStream ms = new MemoryStream();
        ms.Write(wel, 0, 512);
        ms.Write(BitConverter.GetBytes((uint)recs.Count), 0, 4);
        foreach (byte[] r in recs) ms.Write(r, 0, 62);
        return ms.ToArray();
    }

    // ---- pck: AKPK; header_size @4, lang @12, bank @16, stream @20, ext @24;
    // tables at 28: languages, banks, streams, externals (u32 count + 20-byte entries)
    public static List<uint[]> PckStreams(byte[] p) {
        int lang = (int)BitConverter.ToUInt32(p, 12), bank = (int)BitConverter.ToUInt32(p, 16);
        int off = 28 + lang + bank;
        int n = (int)BitConverter.ToUInt32(p, off);
        List<uint[]> l = new List<uint[]>();
        for (int i = 0; i < n; i++) {
            int e = off + 4 + i * 20;
            l.Add(new uint[] { BitConverter.ToUInt32(p, e), BitConverter.ToUInt32(p, e + 4), BitConverter.ToUInt32(p, e + 8), BitConverter.ToUInt32(p, e + 12), BitConverter.ToUInt32(p, e + 16) });
        }
        return l;
    }

    // Writes the pck with new streams added in id order, plus its header-only twin.
    public static long WritePck(byte[] p, Dictionary<uint, string> addFiles, string outFull, string outStub) {
        if (Encoding.ASCII.GetString(p, 0, 4) != "AKPK") throw new Exception("BGM_m.pck is not an AKPK container");
        int hsize = (int)BitConverter.ToUInt32(p, 4), lang = (int)BitConverter.ToUInt32(p, 12), bank = (int)BitConverter.ToUInt32(p, 16);
        int stream = (int)BitConverter.ToUInt32(p, 20), ext = (int)BitConverter.ToUInt32(p, 24);
        if (ext != 4 || BitConverter.ToUInt32(p, 28 + lang + bank + stream) != 0) throw new Exception("unexpected external table in BGM_m.pck");
        List<uint[]> entries = PckStreams(p);
        List<object> sources = new List<object>();
        foreach (uint[] e in entries) sources.Add(null);
        foreach (KeyValuePair<uint, string> kv in addFiles) {
            entries.Add(new uint[] { kv.Key, 1, (uint)new FileInfo(kv.Value).Length, 0, 0 });
        }
        entries.Sort(delegate(uint[] a, uint[] b) { return a[0].CompareTo(b[0]); });
        int add = 20 * addFiles.Count;
        byte[] header = new byte[28 + lang + bank + 4 + 20 * entries.Count + 4];
        Buffer.BlockCopy(p, 0, header, 0, 28 + lang + bank);
        Buffer.BlockCopy(BitConverter.GetBytes((uint)(hsize + add)), 0, header, 4, 4);
        Buffer.BlockCopy(BitConverter.GetBytes((uint)(stream + add)), 0, header, 20, 4);
        int t = 28 + lang + bank;
        Buffer.BlockCopy(BitConverter.GetBytes((uint)entries.Count), 0, header, t, 4);
        Dictionary<uint, uint[]> orig = new Dictionary<uint, uint[]>();
        foreach (uint[] e in PckStreams(p)) orig[e[0]] = e;
        long cursor = header.Length;
        for (int i = 0; i < entries.Count; i++) {
            uint[] e = entries[i];
            e[3] = (uint)cursor;
            cursor += e[2];
            if (cursor > uint.MaxValue) throw new Exception("music pack would exceed 4 GB");
            for (int k = 0; k < 5; k++) Buffer.BlockCopy(BitConverter.GetBytes(e[k]), 0, header, t + 4 + i * 20 + k * 4, 4);
        }
        // externals: count 0 (already zero)
        using (FileStream f = new FileStream(outFull, FileMode.Create, FileAccess.Write)) {
            f.Write(header, 0, header.Length);
            foreach (uint[] e in entries) {
                string file;
                if (addFiles.TryGetValue(e[0], out file)) {
                    byte[] b = File.ReadAllBytes(file);
                    f.Write(b, 0, b.Length);
                } else {
                    uint[] o = orig[e[0]];
                    f.Write(p, (int)o[3], (int)o[2]);
                }
            }
        }
        File.WriteAllBytes(outStub, header);
        return cursor;
    }

    // ---- the vanilla check -------------------------------------------------
    public static string Verify(byte[] oM, byte[] nM, byte[] oE, byte[] nE, byte[] oP, string nPckPath, byte[] oW, byte[] nW) {
        StringBuilder err = new StringBuilder();
        foreach (byte[][] pair in new byte[][][] { new byte[][] { oM, nM }, new byte[][] { oE, nE } }) {
            Dictionary<uint, byte[]> a = Hirc(pair[0]), b = Hirc(pair[1]);
            foreach (KeyValuePair<uint, byte[]> kv in a) {
                byte[] x;
                if (!b.TryGetValue(kv.Key, out x) || !Same(x, kv.Value)) { err.Append("object " + kv.Key + " changed; "); break; }
            }
            foreach (Section s in Sections(pair[0])) {
                if (s.Tag == "HIRC" || s.Tag == "DIDX" || s.Tag == "DATA") continue;
                Section n = Find(pair[1], s.Tag);
                if (n == null || n.Size != s.Size || !SameRange(pair[0], s.Pos, pair[1], n.Pos, 8 + s.Size)) err.Append(s.Tag + " changed; ");
            }
        }
        Dictionary<uint, byte[]> ma = Media(oM), mb = Media(nM);
        foreach (KeyValuePair<uint, byte[]> kv in ma) {
            byte[] x;
            if (!mb.TryGetValue(kv.Key, out x) || !Same(x, kv.Value)) { err.Append("media " + kv.Key + " changed; "); break; }
        }
        using (FileStream f = new FileStream(nPckPath, FileMode.Open, FileAccess.Read)) {
            byte[] head = new byte[1 << 16];
            f.Read(head, 0, head.Length);
            Dictionary<uint, uint[]> ne = new Dictionary<uint, uint[]>();
            foreach (uint[] e in PckStreams(head)) ne[e[0]] = e;
            foreach (uint[] e in PckStreams(oP)) {
                uint[] x;
                if (!ne.TryGetValue(e[0], out x) || x[2] != e[2]) { err.Append("stream " + e[0] + " changed; "); break; }
                byte[] buf = new byte[e[2]];
                f.Seek(x[3], SeekOrigin.Begin);
                int r = 0;
                while (r < buf.Length) { int k = f.Read(buf, r, buf.Length - r); if (k <= 0) break; r += k; }
                if (!SameRange(buf, 0, oP, (int)e[3], (int)e[2])) { err.Append("stream " + e[0] + " changed; "); break; }
            }
        }
        if (!SameRange(oW, 0, nW, 0, 512)) err.Append("event list header changed; ");
        HashSet<string> nr = new HashSet<string>();
        foreach (byte[] r in WelRecords(nW)) nr.Add(Convert.ToBase64String(r));
        foreach (byte[] r in WelRecords(oW)) if (!nr.Contains(Convert.ToBase64String(r))) { err.Append("event record changed; "); break; }
        return err.ToString();
    }

    static bool Same(byte[] a, byte[] b) { return a.Length == b.Length && SameRange(a, 0, b, 0, a.Length); }
    static bool SameRange(byte[] a, int ia, byte[] b, int ib, int n) {
        if (ia + n > a.Length || ib + n > b.Length) return false;
        for (int i = 0; i < n; i++) if (a[ia + i] != b[ib + i]) return false;
        return true;
    }

    public static void SetU32(byte[] b, int off, uint v) { Buffer.BlockCopy(BitConverter.GetBytes(v), 0, b, off, 4); }
    public static uint GetU32(byte[] b, int off) { return BitConverter.ToUInt32(b, off); }
    public static void SetF32(byte[] b, int off, float v) { Buffer.BlockCopy(BitConverter.GetBytes(v), 0, b, off, 4); }
    public static byte[] Slice(byte[] b, int n) { byte[] o = new byte[Math.Min(n, b.Length)]; Buffer.BlockCopy(b, 0, o, 0, o.Length); return o; }

    // A Sound body with its Volume property (prop id 0) set, inserting the
    // property if the template has none. Prop bundle at 28: count, ids, values.
    public static byte[] WithVolume(byte[] body, float vol) {
        int n = body[28];
        for (int i = 0; i < n; i++)
            if (body[29 + i] == 0) { byte[] c = (byte[])body.Clone(); SetF32(c, 29 + n + 4 * i, vol); return c; }
        byte[] o = new byte[body.Length + 5];
        Buffer.BlockCopy(body, 0, o, 0, 28);
        o[28] = (byte)(n + 1);
        o[29] = 0;                                              // Volume first
        Buffer.BlockCopy(body, 29, o, 30, n);                   // the other ids
        SetF32(o, 30 + n, vol);                                 // its value
        Buffer.BlockCopy(body, 29 + n, o, 34 + n, body.Length - 29 - n);  // other values + rest
        return o;
    }
}
"@

# ---- templates: vanilla objects the new ones are cloned from ---------------
# Mall: PA song type 22's two layers (each under its PA speaker mixer), and
# the PA play/stop actions and event-list records of the PA cue (type 42).
# Action: type 1's full-mix Sound, moved to the music containers' bus with
# their -2 dB, and type 1's play/stop actions and records.
# Both Sound templates carry Wwise property 0x3A = 0 (loop forever), so every
# song loops whole until its stop trigger.
$T = @{
    mall_layers   = @(895114650, 706680871)       # parents 215310430 / 442608498
    mall_play_act = 444667351; mall_stop_act = 1041069445
    mall_play_rec = 202812721; mall_stop_rec = 284866585
    # Measured vanilla medians per layer are -34.5 / -37.5. Set 1 dB under:
    # custom music should sit a little below the game's, never above it.
    # (Earlier listens were skewed by ffmpeg's one-pass loudnorm undershooting
    # by 3-6 dB; songs are now measured and gained exactly.)
    mall_lufs     = @(-35.5, -38.5)
    # Colby's plays each PA song's theater version, whose first layer the game
    # masters ~1.8 dB quieter than the plaza one (measured on vanilla 23-27 vs
    # 28-32); it also has 7 speakers to Paradise's 2.
    theater_l0_db = -1.8
    act_sound     = 390762581
    act_play_act  = 408290996; act_stop_act = 17475096
    act_play_rec  = 2263746872; act_stop_rec = 154058866
    act_bus       = 3832016031                     # the music containers' bus
    act_volume    = -2.0                           # the music containers' volume
    # Measured vanilla median is -23, but the vanilla action music itself was
    # judged loud in game; custom Action songs sit clearly below it.
    act_lufs      = -28.0
}

if (-not (Test-Path (Join-Path $GameDir "DRDR.exe"))) {
    Write-Host "DRDR.exe is not in this folder:" -ForegroundColor Red
    Write-Host "  $GameDir"
    Write-Host "Put the DRAP Music Builder files in the Dead Rising Deluxe Remaster install folder and run it again."
    Done 1
}
if (Get-Process -Name "DRDR" -ErrorAction SilentlyContinue) {
    Write-Host "Dead Rising is running. Close the game completely, then run this again." -ForegroundColor Red
    Write-Host "(The game keeps its music files open while it runs.)"
    Done 1
}

$firstRun = -not (Test-Path $MallDir) -or -not (Test-Path $ActionDir)
foreach ($d in @($MusicDir, $MallDir, $ActionDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$LogFile = Join-Path $MusicDir "Music Builder log.txt"
Set-Content -Path $LogFile -Value ("DRAP Music Builder, " + (Get-Date).ToString("s")) -Encoding UTF8
if ($firstRun -and -not $Uninstall) {
    Write-Host "Made the song folders:"
    Write-Host "  $MallDir"
    Write-Host "  $ActionDir"
    Write-Host ""
}
if (-not (Test-Path $Settings)) {
    '{ "mall_gain_db": 0, "action_gain_db": 0 }' | Set-Content -Path $Settings -Encoding ASCII
}

function Remove-Installed {
    if (-not (Test-Path $Manifest)) { return 0 }
    $m = Get-Content -Raw -Path $Manifest | ConvertFrom-Json
    $n = 0
    foreach ($rel in $m.files) {
        $p = Join-Path $GameDir $rel
        if (Test-Path $p) { Remove-Item -Path $p -Force; $n++ }
        $d = Split-Path $p
        while ($d.Length -gt $GameDir.Length -and (Split-Path $d -Leaf) -ne "natives" -and
               (Split-Path $d -Leaf) -ne "data" -and (Test-Path $d) -and -not (Get-ChildItem -Path $d -Force)) {
            Remove-Item -Path $d -Force
            $d = Split-Path $d
        }
    }
    Remove-Item -Path $Manifest -Force
    $list = Join-Path $MusicDir "Installed songs.txt"
    if (Test-Path $list) { Remove-Item -Path $list -Force }
    return $n
}

if ($Uninstall) {
    $n = Remove-Installed
    if ($n -gt 0) { Write-Host "Removed $n file(s). DRAP custom music is uninstalled." -ForegroundColor Green }
    else { Write-Host "No DRAP custom music was installed. Nothing to do." -ForegroundColor Green }
    Write-Host "Your songs in '$MusicDir' were not touched."
    Done 0
}

# Every file this writes; refuse if one exists that we didn't write.
$Targets = @()
foreach ($k in @("bnk_m", "bnk_e", "stub", "pck")) { foreach ($s in $Suffixes) { $Targets += "$($OutBase[$k]).$s" } }
$Targets += $OutWel
$Targets += $LuaList
$owned = @()
if (Test-Path $Manifest) { $owned = @((Get-Content -Raw -Path $Manifest | ConvertFrom-Json).files) }
$foreign = @($Targets | Where-Object { (Test-Path (Join-Path $GameDir $_)) -and ($owned -notcontains $_) })
if ($foreign.Count -gt 0) {
    Write-Host "These music files are already in the game folder, and the DRAP Music Builder did not make them:" -ForegroundColor Red
    $foreign | ForEach-Object { Write-Host "  $_" }
    Write-Host "Another mod is changing the game's music. Remove that mod (or delete these files), then run this again."
    Done 1
}

$ffmpeg = $null
foreach ($c in @((Join-Path $GameDir "ffmpeg.exe"), (Join-Path $MusicDir "ffmpeg.exe"))) { if (Test-Path $c) { $ffmpeg = $c; break } }
if (-not $ffmpeg) { $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue; if ($cmd) { $ffmpeg = $cmd.Source } }
if (-not $ffmpeg) {
    Write-Host "ffmpeg was not found. DRAP uses it to convert your songs, and it is not included." -ForegroundColor Red
    Write-Host "1. Get a Windows build of ffmpeg from the links on https://ffmpeg.org/download.html"
    Write-Host "2. Unzip it and find ffmpeg.exe (it is inside the 'bin' folder)."
    Write-Host "3. Copy ffmpeg.exe into this folder:"
    Write-Host "     $MusicDir"
    Write-Host "4. Run DRAP Music Builder.bat again."
    Done 1
}

function Get-Songs($dir) {
    $files = @(Get-ChildItem -Path $dir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $AudioExt -contains $_.Extension.ToLowerInvariant() })
    if ($files.Count -eq 0) { return , @() }
    # Ordinal order of the upper-cased path inside the pool folder, with '/'
    # separators: the Linux builder (drap_music_builder.py) sorts the same way,
    # so both add songs in the same order and write identical files.
    $root = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\')
    [string[]]$keys = @($files | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/').ToUpperInvariant() })
    [object[]]$arr = $files
    [Array]::Sort($keys, $arr, [StringComparer]::Ordinal)
    return , $arr
}
$songs = @()
foreach ($s in (Get-Songs $MallDir)) { $songs += , @("mall", $s) }
foreach ($s in (Get-Songs $ActionDir)) { $songs += , @("action", $s) }
if ($songs.Count -eq 0) {
    Write-Host "No songs found yet. Put your songs (mp3, ogg, flac, wav, m4a, opus, wma, aac) in:" -ForegroundColor Yellow
    Write-Host "  $MallDir      (songs for the mall's PA speakers)"
    Write-Host "  $ActionDir    (fight, story and event music)"
    Write-Host "then run DRAP Music Builder.bat again."
    Done 0
}
$gain = Get-Content -Raw -Path $Settings | ConvertFrom-Json
$inv = [Globalization.CultureInfo]::InvariantCulture

Write-Host "Reading the game's music from its .pak files..."
$paks = @()
for ($i = 9; $i -ge 1; $i--) { $paks += (Join-Path $GameDir ("re_chunk_000.pak.patch_{0:D3}.pak" -f $i)) }
$paks += (Join-Path $GameDir "re_chunk_000.pak")
$orig = @{}
foreach ($k in $PakNames.Keys) {
    $orig[$k] = [DrapMusic]::ReadFromPaks($paks, $PakNames[$k])
    if (-not $orig[$k]) {
        Write-Host "Could not find the game's music in its .pak files ($($PakNames[$k]))." -ForegroundColor Red
        Write-Host "Make sure DRAP Music Builder.bat is in the Dead Rising Deluxe Remaster folder, next to DRDR.exe and re_chunk_000.pak."
        Done 1
    }
}

# Templates must exist exactly as measured, or the game was updated.
$needM = @($T.mall_layers + @($T.act_sound))
$needE = @($T.mall_play_act, $T.mall_stop_act, $T.act_play_act, $T.act_stop_act)
$hm = [DrapMusic]::Hirc($orig.bnk_m); $he = [DrapMusic]::Hirc($orig.bnk_e)
$missing = @($needM | Where-Object { -not $hm.ContainsKey([uint32]$_) }) + @($needE | Where-Object { -not $he.ContainsKey([uint32]$_) })
foreach ($r in @($T.mall_play_rec, $T.mall_stop_rec, $T.act_play_rec, $T.act_stop_rec)) {
    if (-not [DrapMusic]::WelRecord($orig.wel, [uint32]$r)) { $missing += $r }
}
if ($missing.Count -gt 0) {
    Write-Host "The game's music no longer matches this version of DRAP (missing $($missing -join ', '))." -ForegroundColor Red
    Write-Host "A game update probably changed it. Check for a newer DRAP release."
    Done 1
}

# Every id already in use anywhere, so new ones never collide.
$used = New-Object 'System.Collections.Generic.HashSet[uint32]'
foreach ($k in $hm.Keys) { [void]$used.Add($k) }
foreach ($k in $he.Keys) { [void]$used.Add($k) }
foreach ($e in [DrapMusic]::PckStreams($orig.pck)) { [void]$used.Add($e[0]) }
foreach ($k in ([DrapMusic]::Media($orig.bnk_m)).Keys) { [void]$used.Add($k) }
foreach ($r in [DrapMusic]::WelRecords($orig.wel)) { [void]$used.Add([DrapMusic]::GetU32($r, 0)); [void]$used.Add([DrapMusic]::GetU32($r, 4)) }
function New-Id($name) {
    $salt = 0
    while ($true) {
        $id = [DrapMusic]::Fnv1("drap_music|$name|$salt")
        if ($id -ne 0 -and $used.Add($id)) { return $id }
        $salt++
    }
}

$work = Join-Path $env:TEMP ("DRAP_Music_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$newM = New-Object 'System.Collections.Generic.List[byte[]]'
$newE = New-Object 'System.Collections.Generic.List[byte[]]'
$newW = New-Object 'System.Collections.Generic.List[byte[]]'
$slices = New-Object 'System.Collections.Generic.Dictionary[uint32,byte[]]'
$streams = New-Object 'System.Collections.Generic.Dictionary[uint32,string]'
$lua = @{ version = 1; mall = @(); action = @() }
$report = @()
$total = [long]$orig.pck.Length

# Decodes a song to raw 16-bit PCM at the slot's format, unchanged in level.
function Render($song, $rate, $ch, $out) {
    $ff = @("-v", "error", "-y", "-i", $song.FullName, "-vn",
            "-ar", "$rate", "-ac", "$ch", "-t", "600", "-f", "s16le", "-acodec", "pcm_s16le", $out)
    & $ffmpeg @ff
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw "ffmpeg could not convert '$($song.FullName)'" }
}

# Integrated loudness (EBU R128) of raw PCM, read from ffmpeg's ebur128 summary.
function Get-Lufs($raw, $rate, $ch) {
    $log = "$raw.txt"
    $argl = "-hide_banner -nostats -f s16le -ar $rate -ac $ch -i `"$raw`" -af ebur128=framelog=quiet -f null -"
    $null = Start-Process -FilePath $ffmpeg -ArgumentList $argl -NoNewWindow -Wait -PassThru -RedirectStandardError $log
    $txt = Get-Content -Raw -Path $log
    Remove-Item $log -Force
    $m = [regex]::Matches($txt, "I:\s+(-?[\d.]+|-inf) LUFS")
    if ($m.Count -eq 0) { throw "could not measure the loudness of a converted song" }
    $v = $m[$m.Count - 1].Groups[1].Value
    if ($v -eq "-inf") { return $null }
    return [double]::Parse($v, $inv)
}

# Raw PCM gained to an exact integrated loudness (ffmpeg's volume filter),
# wrapped as a PCM .wem.
function Write-Wem($raw, $measured, $target, $rate, $ch, $out) {
    $g = if ($measured -ne $null) { $target - $measured } else { 0 }
    $gained = "$out.raw"
    $ff = @("-v", "error", "-y", "-f", "s16le", "-ar", "$rate", "-ac", "$ch", "-i", $raw,
            "-af", ("volume={0}dB:precision=double" -f $g.ToString("0.000000", $inv)),
            "-f", "s16le", "-acodec", "pcm_s16le", $gained)
    & $ffmpeg @ff
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $gained)) { throw "ffmpeg could not set the volume of a converted song" }
    [IO.File]::WriteAllBytes($out, [DrapMusic]::PcmWem([IO.File]::ReadAllBytes($gained), $rate, $ch))
    Remove-Item $gained
}

function Add-Sound($templateId, $soundId, $sourceId, $wemPath, $bus, $parentKeep, $volume) {
    $body = [DrapMusic]::Body($orig.bnk_m, [uint32]$templateId)
    # body: plugin u32 @0, stream type u8 @4, source u32 @5, in-memory size u32 @9,
    #       bits u8 @13, fx 4 bytes, attachment @18, bus u32 @19, parent u32 @23
    $mem = [DrapMusic]::GetU32($body, 9)
    [DrapMusic]::SetU32($body, 5, [uint32]$sourceId)
    if ($bus -ne $null) { [DrapMusic]::SetU32($body, 19, [uint32]$bus) }
    if (-not $parentKeep) { [DrapMusic]::SetU32($body, 23, 0) }
    if ($volume -ne $null) { $body = [DrapMusic]::WithVolume($body, [single]$volume) }
    $newM.Add([DrapMusic]::MakeObject(2, [uint32]$soundId, $body))
    if (-not $wemPath) { return }      # shares a source added by another Sound
    $wem = [IO.File]::ReadAllBytes($wemPath)
    $slices[[uint32]$sourceId] = [DrapMusic]::Slice($wem, [int]$mem)
    $streams[[uint32]$sourceId] = $wemPath
}

function Add-Event($actTemplate, $targets, $eventId, $actPrefix) {
    $acts = @()
    $i = 0
    foreach ($t in $targets) {
        $actId = New-Id "$actPrefix|$i"
        $b = [DrapMusic]::Body($orig.bnk_e, [uint32]$actTemplate)
        [DrapMusic]::SetU32($b, 2, [uint32]$t)
        $newE.Add([DrapMusic]::MakeObject(3, [uint32]$actId, $b))
        $acts += $actId; $i++
    }
    $ev = New-Object byte[] (1 + 4 * $acts.Count)
    $ev[0] = [byte]$acts.Count
    for ($k = 0; $k -lt $acts.Count; $k++) { [DrapMusic]::SetU32($ev, 1 + 4 * $k, [uint32]$acts[$k]) }
    $newE.Add([DrapMusic]::MakeObject(4, [uint32]$eventId, $ev))
}

function Add-Trigger($recTemplate, $trig, $eventId) {
    $r = [byte[]]([DrapMusic]::WelRecord($orig.wel, [uint32]$recTemplate)).Clone()
    [DrapMusic]::SetU32($r, 0, [uint32]$trig)
    [DrapMusic]::SetU32($r, 4, [uint32]$eventId)
    $newW.Add($r)
}

try {
    $i = 0
    foreach ($entry in $songs) {
        $pool = $entry[0]; $song = $entry[1]; $i++
        $key = "$pool|$($song.Name)"
        Write-Host ("[{0}/{1}] {2,-6} {3}" -f $i, $songs.Count, $pool, $song.Name)
        $sounds = @()
        if ($pool -eq "mall") {
            $raw = Join-Path $work "$i.raw"
            Render $song 22050 1 $raw
            $measured = Get-Lufs $raw 22050 1
            $srcs = @()
            for ($l = 0; $l -lt 2; $l++) {
                $wem = Join-Path $work "$i.$l.wem"
                Write-Wem $raw $measured ([double]$T.mall_lufs[$l] + [double]$gain.mall_gain_db) 22050 1 $wem
                $sid = New-Id "$key|layer$l|sound"; $src = New-Id "$key|layer$l|source"
                Add-Sound $T.mall_layers[$l] $sid $src $wem $null $true $null
                $sounds += $sid; $srcs += $src
                $total += (Get-Item $wem).Length
            }
            Remove-Item $raw
            # Theater version for Colby's: the same audio, layer 1 quieter,
            # layer 2 shared -- as the game's own theater versions are built.
            $th0 = New-Id "$key|theater0|sound"
            Add-Sound $T.mall_layers[0] $th0 $srcs[0] $null $null $true $T.theater_l0_db
            $theater = @($th0, $sounds[1])
            $playA = $T.mall_play_act; $stopA = $T.mall_stop_act; $playR = $T.mall_play_rec; $stopR = $T.mall_stop_rec
        } else {
            $raw = Join-Path $work "$i.raw"
            Render $song 48000 2 $raw
            $measured = Get-Lufs $raw 48000 2
            $wem = Join-Path $work "$i.wem"
            Write-Wem $raw $measured ([double]$T.act_lufs + [double]$gain.action_gain_db) 48000 2 $wem
            Remove-Item $raw
            $sid = New-Id "$key|sound"; $src = New-Id "$key|source"
            Add-Sound $T.act_sound $sid $src $wem $T.act_bus $false $T.act_volume
            $sounds += $sid
            $total += (Get-Item $wem).Length
            $theater = $null
            $playA = $T.act_play_act; $stopA = $T.act_stop_act; $playR = $T.act_play_rec; $stopR = $T.act_stop_rec
        }
        if ($total -gt $SizeCap) {
            throw "these songs would make the music file larger than 3.5 GB; remove some and run again"
        }
        $playE = New-Id "$key|play_event"; $stopE = New-Id "$key|stop_event"
        Add-Event $playA $sounds $playE "$key|play_action"
        Add-Event $stopA $sounds $stopE "$key|stop_action"
        $playT = New-Id "$key|play_trigger"; $stopT = New-Id "$key|stop_trigger"
        Add-Trigger $playR $playT $playE
        Add-Trigger $stopR $stopT $stopE
        $listEntry = @{ name = $song.Name; play = $playT; stop = $stopT }
        if ($theater) {
            $tpE = New-Id "$key|theater_play_event"; $tsE = New-Id "$key|theater_stop_event"
            Add-Event $playA $theater $tpE "$key|theater_play_action"
            Add-Event $stopA $theater $tsE "$key|theater_stop_action"
            $tpT = New-Id "$key|theater_play_trigger"; $tsT = New-Id "$key|theater_stop_trigger"
            Add-Trigger $playR $tpT $tpE
            Add-Trigger $stopR $tsT $tsE
            $listEntry.theater_play = $tpT; $listEntry.theater_stop = $tsT
        }
        $lua[$pool] += , $listEntry
        $report += ("{0,-6} {1}" -f $pool, $song.Name)
    }

    Write-Host "Building the music files..."
    $bnkM = [DrapMusic]::AddMedia([DrapMusic]::AppendHirc($orig.bnk_m, $newM), $slices)
    $bnkE = [DrapMusic]::AppendHirc($orig.bnk_e, $newE)
    $wel = [DrapMusic]::WelAdd($orig.wel, $newW)
    $outPck = Join-Path $work "pck"; $outStub = Join-Path $work "stub"
    [void][DrapMusic]::WritePck($orig.pck, $streams, $outPck, $outStub)
    $problem = [DrapMusic]::Verify($orig.bnk_m, $bnkM, $orig.bnk_e, $bnkE, $orig.pck, $outPck, $orig.wel, $wel)
    if ($problem) { throw "vanilla check failed: $problem" }
    Write-Host "Checked: every original music object is unchanged."

    [IO.File]::WriteAllBytes((Join-Path $work "bnk_m"), $bnkM)
    [IO.File]::WriteAllBytes((Join-Path $work "bnk_e"), $bnkE)
    $null = Remove-Installed
    $written = @()
    foreach ($k in @("bnk_m", "bnk_e", "stub", "pck")) {
        $src = Join-Path $work $k
        $first = $null
        foreach ($s in $Suffixes) {
            $rel = "$($OutBase[$k]).$s"
            $dst = Join-Path $GameDir $rel
            New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
            if (Test-Path $dst) { Remove-Item $dst -Force }
            if ($first -and [DrapMusic]::HardLink($dst, $first)) { }
            else { Copy-Item -Path $src -Destination $dst -Force; if (-not $first) { $first = $dst } }
            $written += $rel
        }
    }
    $dst = Join-Path $GameDir $OutWel
    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
    [IO.File]::WriteAllBytes($dst, $wel)
    $written += $OutWel
    $dst = Join-Path $GameDir $LuaList
    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
    ($lua | ConvertTo-Json -Depth 5) | Set-Content -Path $dst -Encoding ASCII
    $written += $LuaList

    @{ built = (Get-Date).ToString("s"); files = $written; songs = $report } |
        ConvertTo-Json -Depth 4 | Set-Content -Path $Manifest -Encoding UTF8
    $report | Set-Content -Path (Join-Path $MusicDir "Installed songs.txt") -Encoding UTF8
}
catch {
    Write-Host ""
    Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Nothing in the game folder was changed. The details are in:"
    Write-Host "  $(Join-Path $MusicDir 'Music Builder log.txt')"
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    Done 1
}
Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("Done. Added {0} Mall Music and {1} Action Music song(s)." -f $lua.mall.Count, $lua.action.Count) -ForegroundColor Green
Write-Host "Each seed uses up to 8 Mall songs (one per area with PA speakers) and up to 21 Action songs,"
Write-Host "each at most once; anything left over plays the game's own music."
Write-Host "The game's own music is unchanged. Your songs only play when you are connected to a seed"
Write-Host "with music_shuffle: true in your yaml."
Write-Host "The list of added songs is in: $(Join-Path $MusicDir 'Installed songs.txt')"
Done 0
