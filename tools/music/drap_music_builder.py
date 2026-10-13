#!/usr/bin/env python3
"""DRAP Music Builder for Linux (Steam Proton) -- adds your own songs to Dead
Rising for DRAP's Music Shuffle.

This is the Linux twin of DRAP-MusicBuilder.ps1 (Windows). Both do the same
steps with the same ids, templates, loudness targets and song order, so on the
same songs and the same ffmpeg they write byte-identical game files. Change
one, change the other: tools/logic_tests/test_music_builder_parity.py checks
it.

Put songs in the two folders next to the game:
    <game folder>/DRAP Music/Mall Music/     songs for the mall's PA speakers
    <game folder>/DRAP Music/Action Music/   fight, story and event music
then run "DRAP Music Builder.sh" with the game closed.
"DRAP Music Uninstall.sh" removes everything it added.

Your songs are ADDED to the game's music as new tracks; nothing of the game's
own music is changed or replaced. They only play when you connect to an
Archipelago seed with Music Shuffle on.

Needs python3 (no extra modules) and ffmpeg (from your package manager, or an
ffmpeg binary placed in the "DRAP Music" folder).
"""
import datetime
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

AUDIO_EXT = {".mp3", ".ogg", ".flac", ".wav", ".m4a", ".opus", ".wma", ".aac"}
SIZE_CAP = int(3.5 * 1024 ** 3)
SUFFIXES = ("STM.En", "STM", "X64.En", "X64")
PAK_NAMES = {
    "bnk_m": "natives/STM/Sound/Wwise/BGM_m.bnk.2.X64",
    "bnk_e": "natives/STM/Sound/Wwise/BGM_e.bnk.2.X64",
    "pck": "natives/STM/streaming/Sound/Wwise/BGM_m.pck.3.X64",
    "wel": "natives/STM/Sound/Asset/BGM/EventList/BGM.wel.11",
}
OUT_BASE = {
    "bnk_m": "natives/STM/Sound/Wwise/BGM_m.bnk.2",
    "bnk_e": "natives/STM/Sound/Wwise/BGM_e.bnk.2",
    "stub": "natives/STM/Sound/Wwise/BGM_m.pck.3",
    "pck": "natives/STM/streaming/Sound/Wwise/BGM_m.pck.3",
}
OUT_WEL = "natives/STM/Sound/Asset/BGM/EventList/BGM.wel.11"
LUA_LIST = "reframework/data/DRAP_Music.json"

# Templates and targets: identical to DRAP-MusicBuilder.ps1 (see its notes).
T = {
    "mall_layers": (895114650, 706680871),
    "mall_play_act": 444667351, "mall_stop_act": 1041069445,
    "mall_play_rec": 202812721, "mall_stop_rec": 284866585,
    "mall_lufs": (-35.5, -38.5),
    "theater_l0_db": -1.8,
    "act_sound": 390762581,
    "act_play_act": 408290996, "act_stop_act": 17475096,
    "act_play_rec": 2263746872, "act_stop_rec": 154058866,
    "act_bus": 3832016031,
    "act_volume": -2.0,
    "act_lufs": -28.0,
}

GAME = os.path.dirname(os.path.abspath(__file__))
MUSIC = os.path.join(GAME, "DRAP Music")
MALL = os.path.join(MUSIC, "Mall Music")
ACTION = os.path.join(MUSIC, "Action Music")
MANIFEST = os.path.join(MUSIC, "installed.json")
SETTINGS = os.path.join(MUSIC, "settings.json")
LOG = os.path.join(MUSIC, "Music Builder log.txt")
log_on = False
no_pause = "--no-pause" in sys.argv


def say(text="", color=None):
    codes = {"red": "31", "green": "32", "yellow": "33"}
    if color and sys.stdout.isatty():
        print(f"\033[{codes[color]}m{text}\033[0m")
    else:
        print(text)
    if log_on:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{text}\n")


def done(code):
    if not no_pause and sys.stdin and sys.stdin.isatty():
        print()
        try:
            input("Press Enter to close")
        except EOFError:
            pass
    sys.exit(code)


# ---- case-insensitive paths ------------------------------------------------
# Linux file names are case-sensitive and Proton's are not. Every path is
# resolved component by component, reusing a folder or file that already
# exists under a different case, so nothing gets written twice.
def resolve(rel, base=GAME):
    cur = base
    for part in rel.replace("\\", "/").split("/"):
        hit = None
        if os.path.isdir(cur):
            low = part.lower()
            for name in os.listdir(cur):
                if name.lower() == low:
                    hit = name
                    break
        cur = os.path.join(cur, hit or part)
    return cur


# ---- hashing ---------------------------------------------------------------
def murmur3(data, seed=0xFFFFFFFF):
    c1, c2 = 0xcc9e2d51, 0x1b873593
    h = seed
    n = len(data) // 4
    for i in range(n):
        k = struct.unpack_from("<I", data, i * 4)[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xe6546b64) & 0xFFFFFFFF
    tail = data[n * 4:]
    if tail:
        k = 0
        for i, b in enumerate(tail):
            k |= b << (8 * i)
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
    h ^= len(data)
    h ^= h >> 16
    h = (h * 0x85ebca6b) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0xc2b2ae35) & 0xFFFFFFFF
    h ^= h >> 16
    return h


def fnv1(name):
    h = 2166136261
    for b in name.lower().encode("utf-8"):
        h = (h * 16777619) & 0xFFFFFFFF
        h ^= b
    return h


# ---- paks ------------------------------------------------------------------
def read_from_paks(paks, path):
    lo = murmur3(path.lower().encode("utf-16-le"))
    up = murmur3(path.upper().encode("utf-16-le"))
    for pak in paks:
        if not os.path.isfile(pak):
            continue
        with open(pak, "rb") as f:
            hdr = f.read(16)
            if hdr[:4] != b"KPKA":
                raise RuntimeError(f"{pak} is not an RE Engine pak")
            if struct.unpack_from("<H", hdr, 6)[0] != 0:
                raise RuntimeError(f"{pak} has an encrypted file table; this game version is not supported")
            count = struct.unpack_from("<I", hdr, 8)[0]
            toc = f.read(count * 48)
            for i in range(count):
                e = i * 48
                if struct.unpack_from("<II", toc, e) != (lo, up):
                    continue
                off, csz, rsz, attr = struct.unpack_from("<qqqq", toc, e + 8)
                kind = attr & 0xF
                if kind > 1:
                    raise RuntimeError(f"{path} uses an unsupported compression in {pak}; this game version is not supported")
                f.seek(off)
                data = f.read(csz)
                if len(data) != csz:
                    raise RuntimeError(f"short read in {pak}")
                if kind == 0:
                    return data
                out = zlib.decompress(data, -15)          # raw deflate
                if len(out) != rsz:
                    raise RuntimeError(f"could not unpack {path}")
                return out
    return None


# ---- banks -----------------------------------------------------------------
def sections(d):
    out, pos = [], 0
    while pos + 8 <= len(d):
        tag, size = d[pos:pos + 4], struct.unpack_from("<I", d, pos + 4)[0]
        out.append((tag, pos, size))
        pos += 8 + size
    return out


def find(d, tag):
    return next(((p, z) for t, p, z in sections(d) if t == tag), None)


def hirc(d):
    p0, _ = find(d, b"HIRC")
    n, p, objs = struct.unpack_from("<I", d, p0 + 8)[0], p0 + 12, {}
    for _ in range(n):
        sz, oid = struct.unpack_from("<II", d, p + 1)
        objs[oid] = d[p:p + 5 + sz]
        p += 5 + sz
    return objs


def body(bnk, oid):
    obj = hirc(bnk).get(oid)
    return bytearray(obj[9:]) if obj is not None else None


def make_object(typ, oid, b):
    return struct.pack("<BII", typ, 4 + len(b), oid) + bytes(b)


def append_hirc(d, objs):
    blob = b"".join(objs)
    out = bytearray()
    for tag, pos, size in sections(d):
        if tag != b"HIRC":
            out += d[pos:pos + 8 + size]
            continue
        n = struct.unpack_from("<I", d, pos + 8)[0]
        out += b"HIRC" + struct.pack("<II", size + len(blob), n + len(objs))
        out += d[pos + 12:pos + 8 + size] + blob
    return bytes(out)


def add_media(d, slices):
    dp, dz = find(d, b"DIDX")
    ap, az = find(d, b"DATA")
    entries = [list(struct.unpack_from("<III", d, dp + 8 + i * 12)) for i in range(dz // 12)]
    data = bytearray(d[ap + 8:ap + 8 + az])
    for sid, blob in slices.items():
        data += b"\0" * ((-len(data)) % 16)
        entries.append([sid, len(data), len(blob)])
        data += blob
    entries.sort(key=lambda e: e[0])
    out = bytearray()
    for tag, pos, size in sections(d):
        if tag == b"DIDX":
            out += b"DIDX" + struct.pack("<I", 12 * len(entries)) + b"".join(struct.pack("<III", *e) for e in entries)
        elif tag == b"DATA":
            out += b"DATA" + struct.pack("<I", len(data)) + data
        else:
            out += d[pos:pos + 8 + size]
    return bytes(out)


def media(d):
    di = find(d, b"DIDX")
    if not di:
        return {}
    dp, dz = di
    ap = find(d, b"DATA")[0] + 8
    out = {}
    for i in range(dz // 12):
        sid, off, sz = struct.unpack_from("<III", d, dp + 8 + i * 12)
        out[sid] = d[ap + off:ap + off + sz]
    return out


def with_volume(b, vol):
    n = b[28]
    for i in range(n):
        if b[29 + i] == 0:
            c = bytearray(b)
            struct.pack_into("<f", c, 29 + n + 4 * i, vol)
            return c
    o = bytearray(b[:28]) + bytes([n + 1, 0]) + b[29:29 + n] + struct.pack("<f", vol) + b[29 + n:]
    return o


# ---- event list ------------------------------------------------------------
def wel_records(w):
    n = struct.unpack_from("<I", w, 512)[0]
    return [w[516 + i * 62:516 + (i + 1) * 62] for i in range(n)]


def wel_record(w, trig):
    return next((r for r in wel_records(w) if struct.unpack_from("<I", r, 0)[0] == trig), None)


def wel_add(w, add):
    recs = sorted(wel_records(w) + list(add), key=lambda r: struct.unpack_from("<I", r, 0)[0])
    return w[:512] + struct.pack("<I", len(recs)) + b"".join(recs)


# ---- pck -------------------------------------------------------------------
def pck_streams(p):
    lang, bank = struct.unpack_from("<II", p, 12)
    off = 28 + lang + bank
    n = struct.unpack_from("<I", p, off)[0]
    return [list(struct.unpack_from("<IIIII", p, off + 4 + i * 20)) for i in range(n)]


def write_pck(p, add_files, out_full, out_stub):
    if p[:4] != b"AKPK":
        raise RuntimeError("BGM_m.pck is not an AKPK container")
    hsize, _, lang, bank, stream, ext = struct.unpack_from("<IIIIII", p, 4)
    if ext != 4 or struct.unpack_from("<I", p, 28 + lang + bank + stream)[0] != 0:
        raise RuntimeError("unexpected external table in BGM_m.pck")
    orig = {e[0]: e for e in pck_streams(p)}
    entries = [list(e) for e in pck_streams(p)]
    for sid, path in add_files.items():
        entries.append([sid, 1, os.path.getsize(path), 0, 0])
    entries.sort(key=lambda e: e[0])
    add = 20 * len(add_files)
    header = bytearray(p[:28 + lang + bank]) + bytearray(4 + 20 * len(entries) + 4)
    struct.pack_into("<I", header, 4, hsize + add)
    struct.pack_into("<I", header, 20, stream + add)
    t = 28 + lang + bank
    struct.pack_into("<I", header, t, len(entries))
    cursor = len(header)
    for i, e in enumerate(entries):
        e[3] = cursor
        cursor += e[2]
        if cursor > 0xFFFFFFFF:
            raise RuntimeError("music pack would exceed 4 GB")
        struct.pack_into("<IIIII", header, t + 4 + i * 20, *e)
    with open(out_full, "wb") as f:
        f.write(header)
        for e in entries:
            if e[0] in add_files:
                with open(add_files[e[0]], "rb") as src:
                    shutil.copyfileobj(src, f)
            else:
                o = orig[e[0]]
                f.write(p[o[3]:o[3] + o[2]])
    with open(out_stub, "wb") as f:
        f.write(header)
    return cursor


# ---- the vanilla check -----------------------------------------------------
def verify(o_m, n_m, o_e, n_e, o_p, n_pck_path, o_w, n_w):
    err = []
    for a_b, b_b in ((o_m, n_m), (o_e, n_e)):
        a, b = hirc(a_b), hirc(b_b)
        if any(b.get(k) != v for k, v in a.items()):
            err.append("a bank object changed")
        for tag, pos, size in sections(a_b):
            if tag in (b"HIRC", b"DIDX", b"DATA"):
                continue
            nb = find(b_b, tag)
            if not nb or nb[1] != size or a_b[pos:pos + 8 + size] != b_b[nb[0]:nb[0] + 8 + size]:
                err.append(f"{tag.decode()} changed")
    ma, mb = media(o_m), media(n_m)
    if any(mb.get(k) != v for k, v in ma.items()):
        err.append("media changed")
    with open(n_pck_path, "rb") as f:
        head = f.read(1 << 16)
        ne = {e[0]: e for e in pck_streams(head)}
        for e in pck_streams(o_p):
            x = ne.get(e[0])
            if not x or x[2] != e[2]:
                err.append(f"stream {e[0]} changed")
                break
            f.seek(x[3])
            if f.read(e[2]) != o_p[e[3]:e[3] + e[2]]:
                err.append(f"stream {e[0]} changed")
                break
    if o_w[:512] != n_w[:512]:
        err.append("event list header changed")
    if not set(wel_records(o_w)) <= set(wel_records(n_w)):
        err.append("event record changed")
    return "; ".join(err)


def pcm_wem(pcm, rate, ch):
    chcfg = {1: (0x4 << 12) | (1 << 8) | 1, 2: (0x3 << 12) | (1 << 8) | 2}[ch]
    fmt = struct.pack("<HHIIHHHHI", 0xFFFE, ch, rate, rate * 2 * ch, 2 * ch, 16, 6, 0, chcfg)
    b = b"WAVE" + b"fmt " + struct.pack("<I", 24) + fmt + b"data" + struct.pack("<I", len(pcm)) + pcm
    return b"RIFF" + struct.pack("<I", len(b)) + b


# ---- process checks --------------------------------------------------------
def game_running():
    """Under Proton the game is a process whose command line names DRDR.exe."""
    pgrep = shutil.which("pgrep")
    if not pgrep:
        return False
    r = subprocess.run([pgrep, "-f", "-i", r"DRDR\.exe"], capture_output=True)
    return r.returncode == 0


def find_ffmpeg():
    for c in (os.path.join(MUSIC, "ffmpeg"), os.path.join(GAME, "ffmpeg")):
        if os.path.isfile(c):
            if not os.access(c, os.X_OK):
                try:
                    os.chmod(c, 0o755)
                except OSError:
                    pass
            return c
    return shutil.which("ffmpeg")


# ---- main --------------------------------------------------------------------
def main():
    global log_on
    uninstall = "--uninstall" in sys.argv
    if not os.path.isfile(resolve("DRDR.exe")):
        say("DRDR.exe is not in this folder:", "red")
        say(f"  {GAME}")
        say("Put the DRAP Music Builder files in the Dead Rising Deluxe Remaster install folder and run it again.")
        done(1)
    if game_running():
        say("Dead Rising is running. Close the game completely, then run this again.", "red")
        say("(The game keeps its music files open while it runs.)")
        done(1)

    global MUSIC, MALL, ACTION, MANIFEST, SETTINGS, LOG
    MUSIC = resolve("DRAP Music")
    MALL, ACTION = resolve("Mall Music", MUSIC), resolve("Action Music", MUSIC)
    MANIFEST, SETTINGS = os.path.join(MUSIC, "installed.json"), os.path.join(MUSIC, "settings.json")
    LOG = os.path.join(MUSIC, "Music Builder log.txt")
    first_run = not (os.path.isdir(MALL) and os.path.isdir(ACTION))
    for d in (MUSIC, MALL, ACTION):
        os.makedirs(d, exist_ok=True)
    with open(LOG, "w", encoding="utf-8") as f:
        f.write(f"DRAP Music Builder (Linux), {datetime.datetime.now().replace(microsecond=0).isoformat()}\n")
    log_on = True
    if first_run and not uninstall:
        say("Made the song folders:")
        say(f"  {MALL}")
        say(f"  {ACTION}")
        say()
    if not os.path.isfile(SETTINGS):
        with open(SETTINGS, "w", encoding="ascii") as f:
            f.write('{ "mall_gain_db": 0, "action_gain_db": 0 }\n')

    def remove_installed():
        if not os.path.isfile(MANIFEST):
            return 0
        with open(MANIFEST, encoding="utf-8-sig") as f:
            m = json.load(f)
        n = 0
        for rel in m.get("files", []):
            p = resolve(rel)
            if os.path.lexists(p):
                os.remove(p)
                n += 1
            d = os.path.dirname(p)
            while (len(d) > len(GAME) and os.path.basename(d).lower() not in ("natives", "data")
                   and os.path.isdir(d) and not os.listdir(d)):
                os.rmdir(d)
                d = os.path.dirname(d)
        os.remove(MANIFEST)
        lst = os.path.join(MUSIC, "Installed songs.txt")
        if os.path.isfile(lst):
            os.remove(lst)
        return n

    if uninstall:
        n = remove_installed()
        if n > 0:
            say(f"Removed {n} file(s). DRAP custom music is uninstalled.", "green")
        else:
            say("No DRAP custom music was installed. Nothing to do.", "green")
        say(f"Your songs in '{MUSIC}' were not touched.")
        done(0)

    targets = [f"{OUT_BASE[k]}.{s}" for k in ("bnk_m", "bnk_e", "stub", "pck") for s in SUFFIXES]
    targets += [OUT_WEL, LUA_LIST]
    owned = []
    if os.path.isfile(MANIFEST):
        with open(MANIFEST, encoding="utf-8-sig") as f:
            owned = [r.replace("\\", "/").lower() for r in json.load(f).get("files", [])]
    foreign = [t for t in targets if os.path.lexists(resolve(t)) and t.lower() not in owned]
    if foreign:
        say("These music files are already in the game folder, and the DRAP Music Builder did not make them:", "red")
        for t in foreign:
            say(f"  {t}")
        say("Another mod is changing the game's music. Remove that mod (or delete these files), then run this again.")
        done(1)

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        say("ffmpeg was not found. DRAP uses it to convert your songs, and it is not included.", "red")
        say("Install it with your package manager, for example:")
        say("  sudo apt install ffmpeg      (Ubuntu, Debian, Mint, Pop!_OS)")
        say("  sudo dnf install ffmpeg      (Fedora)")
        say("  sudo pacman -S ffmpeg        (Arch, Manjaro)")
        say("Or, on a Steam Deck or anywhere you can't install packages, download a Linux build")
        say("from the links on https://ffmpeg.org/download.html and copy its 'ffmpeg' file into:")
        say(f"     {MUSIC}")
        say("Then run DRAP Music Builder.sh again.")
        done(1)

    def get_songs(d):
        files = []
        for root, _, names in os.walk(d):
            for nm in names:
                if os.path.splitext(nm)[1].lower() in AUDIO_EXT:
                    full = os.path.join(root, nm)
                    files.append((os.path.relpath(full, d).replace("\\", "/").upper(), nm, full))
        files.sort(key=lambda x: x[0])     # same order as the Windows builder
        return files

    songs = [("mall", s) for s in get_songs(MALL)] + [("action", s) for s in get_songs(ACTION)]
    if not songs:
        say("No songs found yet. Put your songs (mp3, ogg, flac, wav, m4a, opus, wma, aac) in:", "yellow")
        say(f"  {MALL}      (songs for the mall's PA speakers)")
        say(f"  {ACTION}    (fight, story and event music)")
        say("then run DRAP Music Builder.sh again.")
        done(0)
    with open(SETTINGS, encoding="utf-8-sig") as f:
        gain = json.load(f)

    say("Reading the game's music from its .pak files...")
    paks = [resolve(f"re_chunk_000.pak.patch_{i:03d}.pak") for i in range(9, 0, -1)] + [resolve("re_chunk_000.pak")]
    orig = {}
    for k, path in PAK_NAMES.items():
        orig[k] = read_from_paks(paks, path)
        if orig[k] is None:
            say(f"Could not find the game's music in its .pak files ({path}).", "red")
            say("Make sure DRAP Music Builder.sh is in the Dead Rising Deluxe Remaster folder, next to DRDR.exe and re_chunk_000.pak.")
            done(1)

    hm, he = hirc(orig["bnk_m"]), hirc(orig["bnk_e"])
    missing = [x for x in (*T["mall_layers"], T["act_sound"]) if x not in hm]
    missing += [x for x in (T["mall_play_act"], T["mall_stop_act"], T["act_play_act"], T["act_stop_act"]) if x not in he]
    missing += [r for r in (T["mall_play_rec"], T["mall_stop_rec"], T["act_play_rec"], T["act_stop_rec"])
                if wel_record(orig["wel"], r) is None]
    if missing:
        say(f"The game's music no longer matches this version of DRAP (missing {', '.join(map(str, missing))}).", "red")
        say("A game update probably changed it. Check for a newer DRAP release.")
        done(1)

    used = set(hm) | set(he) | {e[0] for e in pck_streams(orig["pck"])} | set(media(orig["bnk_m"]))
    for r in wel_records(orig["wel"]):
        used.update(struct.unpack_from("<II", r, 0))

    def new_id(name):
        salt = 0
        while True:
            i = fnv1(f"drap_music|{name}|{salt}")
            if i != 0 and i not in used:
                used.add(i)
                return i
            salt += 1

    work = os.path.join(tempfile.gettempdir(), "DRAP_Music_" + uuid.uuid4().hex)
    os.makedirs(work)
    new_m, new_e, new_w = [], [], []
    slices, streams = {}, {}
    lua = {"version": 1, "mall": [], "action": []}
    report = []
    total = len(orig["pck"])

    def run_ffmpeg(args, what):
        r = subprocess.run([ffmpeg] + args, capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(what)
        return r

    def render(path, rate, ch, out):
        run_ffmpeg(["-v", "error", "-y", "-i", path, "-vn", "-ar", str(rate), "-ac", str(ch), "-t", "600",
                    "-f", "s16le", "-acodec", "pcm_s16le", out], f"ffmpeg could not convert '{path}'")

    def get_lufs(raw, rate, ch):
        r = run_ffmpeg(["-hide_banner", "-nostats", "-f", "s16le", "-ar", str(rate), "-ac", str(ch), "-i", raw,
                        "-af", "ebur128=framelog=quiet", "-f", "null", "-"],
                       "could not measure the loudness of a converted song")
        m = re.findall(r"I:\s+(-?[\d.]+|-inf) LUFS", r.stderr.decode("utf-8", "replace"))
        if not m:
            raise RuntimeError("could not measure the loudness of a converted song")
        return None if m[-1] == "-inf" else float(m[-1])

    def write_wem(raw, measured, target, rate, ch, out):
        g = (target - measured) if measured is not None else 0.0
        gained = out + ".raw"
        run_ffmpeg(["-v", "error", "-y", "-f", "s16le", "-ar", str(rate), "-ac", str(ch), "-i", raw,
                    "-af", f"volume={g:.6f}dB:precision=double", "-f", "s16le", "-acodec", "pcm_s16le", gained],
                   "ffmpeg could not set the volume of a converted song")
        with open(gained, "rb") as f:
            pcm = f.read()
        with open(out, "wb") as f:
            f.write(pcm_wem(pcm, rate, ch))
        os.remove(gained)

    def add_sound(template, sound_id, source_id, wem_path, bus, parent_keep, volume):
        b = body(orig["bnk_m"], template)
        mem = struct.unpack_from("<I", b, 9)[0]
        struct.pack_into("<I", b, 5, source_id)
        if bus is not None:
            struct.pack_into("<I", b, 19, bus)
        if not parent_keep:
            struct.pack_into("<I", b, 23, 0)
        if volume is not None:
            b = with_volume(b, volume)
        new_m.append(make_object(2, sound_id, b))
        if not wem_path:
            return
        with open(wem_path, "rb") as f:
            slices[source_id] = f.read(mem)
        streams[source_id] = wem_path

    def add_event(act_template, targets, event_id, act_prefix):
        acts = []
        for i, t in enumerate(targets):
            act_id = new_id(f"{act_prefix}|{i}")
            b = body(orig["bnk_e"], act_template)
            struct.pack_into("<I", b, 2, t)
            new_e.append(make_object(3, act_id, b))
            acts.append(act_id)
        new_e.append(make_object(4, event_id, bytes([len(acts)]) + b"".join(struct.pack("<I", a) for a in acts)))

    def add_trigger(rec_template, trig, event_id):
        r = bytearray(wel_record(orig["wel"], rec_template))
        struct.pack_into("<II", r, 0, trig, event_id)
        new_w.append(bytes(r))

    try:
        for i, (pool, (_, name, path)) in enumerate(songs, 1):
            key = f"{pool}|{name}"
            say(f"[{i}/{len(songs)}] {pool:<6} {name}")
            sounds = []
            raw = os.path.join(work, f"{i}.raw")
            if pool == "mall":
                render(path, 22050, 1, raw)
                measured = get_lufs(raw, 22050, 1)
                srcs = []
                for l in range(2):
                    wem = os.path.join(work, f"{i}.{l}.wem")
                    write_wem(raw, measured, T["mall_lufs"][l] + float(gain.get("mall_gain_db", 0)), 22050, 1, wem)
                    sid, src = new_id(f"{key}|layer{l}|sound"), new_id(f"{key}|layer{l}|source")
                    add_sound(T["mall_layers"][l], sid, src, wem, None, True, None)
                    sounds.append(sid)
                    srcs.append(src)
                    total += os.path.getsize(wem)
                os.remove(raw)
                th0 = new_id(f"{key}|theater0|sound")
                add_sound(T["mall_layers"][0], th0, srcs[0], None, None, True, T["theater_l0_db"])
                theater = [th0, sounds[1]]
                play_a, stop_a, play_r, stop_r = T["mall_play_act"], T["mall_stop_act"], T["mall_play_rec"], T["mall_stop_rec"]
            else:
                render(path, 48000, 2, raw)
                measured = get_lufs(raw, 48000, 2)
                wem = os.path.join(work, f"{i}.wem")
                write_wem(raw, measured, T["act_lufs"] + float(gain.get("action_gain_db", 0)), 48000, 2, wem)
                os.remove(raw)
                sid, src = new_id(f"{key}|sound"), new_id(f"{key}|source")
                add_sound(T["act_sound"], sid, src, wem, T["act_bus"], False, T["act_volume"])
                sounds.append(sid)
                total += os.path.getsize(wem)
                theater = None
                play_a, stop_a, play_r, stop_r = T["act_play_act"], T["act_stop_act"], T["act_play_rec"], T["act_stop_rec"]
            if total > SIZE_CAP:
                raise RuntimeError("these songs would make the music file larger than 3.5 GB; remove some and run again")
            play_e, stop_e = new_id(f"{key}|play_event"), new_id(f"{key}|stop_event")
            add_event(play_a, sounds, play_e, f"{key}|play_action")
            add_event(stop_a, sounds, stop_e, f"{key}|stop_action")
            play_t, stop_t = new_id(f"{key}|play_trigger"), new_id(f"{key}|stop_trigger")
            add_trigger(play_r, play_t, play_e)
            add_trigger(stop_r, stop_t, stop_e)
            entry = {"name": name, "play": play_t, "stop": stop_t}
            if theater:
                tp_e, ts_e = new_id(f"{key}|theater_play_event"), new_id(f"{key}|theater_stop_event")
                add_event(play_a, theater, tp_e, f"{key}|theater_play_action")
                add_event(stop_a, theater, ts_e, f"{key}|theater_stop_action")
                tp_t, ts_t = new_id(f"{key}|theater_play_trigger"), new_id(f"{key}|theater_stop_trigger")
                add_trigger(play_r, tp_t, tp_e)
                add_trigger(stop_r, ts_t, ts_e)
                entry["theater_play"], entry["theater_stop"] = tp_t, ts_t
            lua[pool].append(entry)
            report.append(f"{pool:<6} {name}")

        say("Building the music files...")
        bnk_m = add_media(append_hirc(orig["bnk_m"], new_m), slices)
        bnk_e = append_hirc(orig["bnk_e"], new_e)
        wel = wel_add(orig["wel"], new_w)
        out_pck, out_stub = os.path.join(work, "pck"), os.path.join(work, "stub")
        write_pck(orig["pck"], streams, out_pck, out_stub)
        problem = verify(orig["bnk_m"], bnk_m, orig["bnk_e"], bnk_e, orig["pck"], out_pck, orig["wel"], wel)
        if problem:
            raise RuntimeError(f"vanilla check failed: {problem}")
        say("Checked: every original music object is unchanged.")

        for k, data in (("bnk_m", bnk_m), ("bnk_e", bnk_e)):
            with open(os.path.join(work, k), "wb") as f:
                f.write(data)
        remove_installed()
        written = []
        for k in ("bnk_m", "bnk_e", "stub", "pck"):
            src = os.path.join(work, k)
            first = None
            for s in SUFFIXES:
                rel = f"{OUT_BASE[k]}.{s}"
                dst = resolve(rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if os.path.lexists(dst):
                    os.remove(dst)
                linked = False
                if first:
                    try:
                        os.link(first, dst)       # one copy on disk, four names
                        linked = True
                    except OSError:
                        pass
                if not linked:
                    shutil.copyfile(src, dst)
                    first = first or dst
                written.append(rel)
        dst = resolve(OUT_WEL)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(wel)
        written.append(OUT_WEL)
        dst = resolve(LUA_LIST)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="ascii") as f:
            json.dump(lua, f, indent=2)
        written.append(LUA_LIST)
        with open(MANIFEST, "w", encoding="utf-8") as f:
            json.dump({"built": datetime.datetime.now().replace(microsecond=0).isoformat(),
                       "files": written, "songs": report}, f, indent=2)
        with open(os.path.join(MUSIC, "Installed songs.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(report) + "\n")
    except Exception as e:  # noqa: BLE001 -- every failure is reported the same way
        say()
        say(f"Failed: {e}", "red")
        say("Nothing in the game folder was changed. The details are in:")
        say(f"  {LOG}")
        shutil.rmtree(work, ignore_errors=True)
        done(1)
    shutil.rmtree(work, ignore_errors=True)

    say()
    say(f"Done. Added {len(lua['mall'])} Mall Music and {len(lua['action'])} Action Music song(s).", "green")
    say("Each seed uses up to 8 Mall songs (one per area with PA speakers) and up to 21 Action songs,")
    say("each at most once; anything left over plays the game's own music.")
    say("The game's own music is unchanged. Your songs only play when you are connected to a seed")
    say("with music_shuffle: true in your yaml.")
    say(f"The list of added songs is in: {os.path.join(MUSIC, 'Installed songs.txt')}")
    done(0)


if __name__ == "__main__":
    main()
