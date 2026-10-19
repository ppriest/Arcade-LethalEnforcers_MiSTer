#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra files, and check each one byte for byte.

    python scripts/build_mra.py                 # every set in SETS -> releases/
    python scripts/build_mra.py lethalenj       # one set
    python scripts/build_mra.py --check         # verify only, write nothing

THE STREAM (ioctl index 0) is what rtl/lethal_sdram.sv expects, in the order of its
DL_* localparams, which are read from the RTL:

  main      the set's program ROM
  tiles     MAME's k056832 region (ROM_LOAD32_WORD pairs)
  sprites   the first half of MAME's k053244 region, then 191A06 as its file
  sound     the Z80 program
  samples   MAME's k054539 region

The expected stream is built from the regions scripts/render_model.py loads (the ones
the frame checks against MAME used); each interleave's map is the one that reproduces
its region, never reasoned about. The written .mra is re-read with scripts/mra.py
(mra-tools-c's semantics) and its whole image compared with the stream.

index 1, the mod byte: bit 0 the screen is MAME's FLIP_X (else FLIP_Y), bit 1 the gun
axes are reversed (PORT_REVERSE in the set's LIGHT ports).
index 2: the set's default EEPROM image; <nvram index="4"> the saved one.
index 254: the DSW port's bits 4-7 as DIP bits 0-3.
"""
import argparse
import itertools
import re
import sys
import zipfile
import zlib
from pathlib import Path
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import extract_dips as ed      # noqa: E402
import mra as mra_lib          # noqa: E402
import render_model as rm      # noqa: E402
from mame_capture import mame_paths, rompath   # noqa: E402

DRIVER = Path("E:/mame/src/mame/konami/lethal.cpp")
OUT_DIR = REPO / "releases"
RBF = "LethalEnforcers"
SETS = ["lethalen", "lethalenub", "lethalenua", "lethalenux", "lethaleneae", "lethalenead",
        "lethaleneab", "lethaleneaa", "lethalenj"]
OSD_COLS = 28
# positional, joystick bit 4 + i, as LethalEnforcers.sv's J1 line and gx_keyboard.sv:
# six game slots, then Start, Coin, Pause, Service. Main_MiSTer gives `default` to the
# named buttons in order, so it lists one pad button per name.
BUTTONS = ('names="Trigger,Reload,-,-,-,-,Start,Coin,Pause,Service" '
           'default="A,B,Start,Select,L,R" count="2"')


def esc(s):
    return escape(str(s), {'"': "&quot;"})


def mame_version():
    import subprocess
    mame_dir, exe = mame_paths()
    out = subprocess.run([str(exe), "-version"], capture_output=True, text=True, timeout=30).stdout
    m = re.match(r"\s*0\.(\d+)", out)
    if not m:
        sys.exit(f"cannot read the MAME version from {exe}")
    return "%04d" % int(m.group(1))


# hiscore.v: MAME's hiscore.dat entries (KonamiGX's scheme). HS_READY_FRAME is the frame
# from power-on after which the set's own table stays in place (scripts/hs_ready.py).
# scripts/hs_ready.py: the frame each set writes its table, unchanged after to 1800
HS_READY_FRAME = {"lethalen": 348, "lethalenub": 419, "lethalenead": 419}
WRAM = (0x2000, 0x4000)                 # lethal_main's work RAM
HS_MAX_ENTRIES, HS_MAX_BYTES = 4, 256


def hiscore_dat():
    """MAME's plugins/hiscore/hiscore.dat beside the MAME this script runs, or None."""
    mame_dir, _ = mame_paths()
    f = Path(mame_dir) / "plugins" / "hiscore" / "hiscore.dat"
    return f.read_text(encoding="utf-8", errors="replace") if f.exists() else None


def hiscore_entries(set_name, text, check_ready=True):
    """[(addr, length, start, end)] for the set; [] if none, or one this core cannot hold."""
    names, entries, found = [], [], None
    for ln in (text or "").splitlines() + [""]:
        ln = ln.strip()
        if ln.startswith(";"):
            continue
        if ln.endswith(":") and not ln.startswith("@"):
            if entries:
                names, entries = [], []
            names.append(ln[:-1])
        elif ln.startswith("@"):
            f = ln[1:].split(",")
            try:
                entries.append((f[0], f[1], int(f[2], 16), int(f[3], 16), int(f[4], 16), int(f[5], 16)))
            except (IndexError, ValueError):
                entries.append(("?", "?", 0, 0, 0, 0))
        elif not ln and names:
            if set_name in names and entries:
                found = entries
                break
            names, entries = [], []
    if not found:
        return []
    out = [(a, n, s, e) for cpu, space, a, n, s, e in found
           if cpu == ":maincpu" and space == "program" and WRAM[0] <= a and a + n <= WRAM[1]]
    if (len(out) != len(found) or len(out) > HS_MAX_ENTRIES or sum(n for _, n, _, _ in out) > HS_MAX_BYTES
            or (check_ready and set_name not in HS_READY_FRAME)):
        return []
    return out


FRAME_CLKS = 384 * 262 * 8             # clk_sys clocks a frame (lethal_video's raster)


def hiscore_lines(set_name):
    """The <rom index="3"> block, and the bytes hiscore.v adds to the <nvram> file."""
    ents = hiscore_entries(set_name, hiscore_dat())
    if not ents:
        return [], 0
    # START_WAIT: half a second before the table settles, counted from the board's reset
    wait = (HS_READY_FRAME[set_name] - 30) * FRAME_CLKS
    # START_WAIT, CHECK_WAIT, CHECK_HOLD, WRITE_HOLD, WRITE_REPEATCOUNT, WRITE_REPEATWAIT,
    # ACCESS_PAUSEPAD, CHANGEMASK (KonamiGX's values)
    head = wait.to_bytes(4, "big") + bytes.fromhex("3FFF 0002 0002 0001 000F 20 00")
    rows = [" ".join(f"{b:02X}" for b in head)]
    for a, n, st, en in ents:              # CFG_LENGTHWIDTH 2: address, length, start, end
        rows.append(" ".join(f"{b:02X}" for b in a.to_bytes(4, "big") + n.to_bytes(2, "big") + bytes([st, en])))
    return (["", "    <!-- MAME's hiscore.dat entries for hiscore.v (rtl/hiscore) -->",
             '    <rom index="3">', "        <part>", *("        " + r for r in rows),
             "        </part>", "    </rom>"],
            sum(n for _, n, _, _ in ents))


def dl_map():
    src = (REPO / "rtl" / "lethal_sdram.sv").read_text()
    m = dict((k, int(v, 16)) for k, v in re.findall(r"localparam \[24:0\] (DL_\w+)\s*=\s*25'h([0-9a-fA-F]+)", src))
    order = ["DL_MAIN", "DL_TILES", "DL_SPRITES", "DL_SPR06", "DL_SOUND", "DL_SAMPLES", "DL_END"]
    for k in order:
        if k not in m:
            sys.exit(f"{k} missing from rtl/lethal_sdram.sv")
    return [m[k] for k in order]


def driver():
    return DRIVER.read_text(encoding="utf8", errors="replace")


def games(text):
    out = {}
    for m in re.finditer(r'^GAME\(\s*(\d+),\s*(\w+),\s*(\w+),\s*\w+,\s*(\w+),[^,]*,[^,]*,\s*(ORIENTATION_FLIP_[XY]|ROT\d+),'
                         r'\s*"([^"]*)",\s*"([^"]*)"', text, re.M):
        out[m.group(2)] = dict(year=m.group(1), parent=m.group(3), inputs=m.group(4),
                               orient=m.group(5), manufacturer=m.group(6), title=m.group(7))
    return out


def romstart(text, set_name):
    """{region: [(name, offset, length, crc)]} from the set's ROM_START."""
    m = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % set_name, text, re.S)
    regions, cur = {}, None
    for ln in m.group(1).splitlines():
        r = re.search(r'ROM_REGION\(\s*\w+,\s*"(\w+)"', ln)
        if r:
            cur = r.group(1); regions[cur] = []
            continue
        r = re.search(r'ROM_LOAD\w*\(\s*"([^"]+)",\s*(\w+),\s*(\w+),\s*CRC\((\w+)\)', ln)
        if r:
            regions[cur].append((r.group(1), int(r.group(2), 0), int(r.group(3), 0), int(r.group(4), 16)))
    return regions


def zips_for(set_name, parent):
    mame_dir, _ = mame_paths()
    names = [f"{set_name}.zip"] + ([f"{parent}.zip"] if parent != "0" else [])
    found = []
    for d in rompath(mame_dir).split(";"):
        for n in names:
            if (Path(d) / n).exists():
                found.append(Path(d) / n)
    return names, found


def read_crc(zs, name, crc):
    return mra_lib._zip_read(zs, name, crc)


def pick_maps(datas, truth):
    """The two maps (output 32) that make mra-tools-c's interleave of datas equal truth."""
    cands = ["".join(p) for p in itertools.permutations("0012")]
    cands = sorted(set(c for c in cands if c.replace("0", "") in ("12", "21") and
                       abs(c.index(c.replace("0", "")[0]) - c.index(c.replace("0", "")[1])) == 1))
    for maps in itertools.product(cands, repeat=2):
        used = [set(i for i, c in enumerate(m) if c != "0") for m in maps]
        if used[0] & used[1]:
            continue
        head = [d[:8192] for d in datas]
        if mra_lib.interleave(list(zip(head, maps)), 32) != truth[:16384]:
            continue
        if mra_lib.interleave(list(zip(datas, maps)), 32) == truth:
            return list(maps)
    sys.exit("no map pair reproduces this region")


def dips(text, inputs):
    blocks = ed.blocks(text)
    missing = set()
    ports = ed.parse_ports(blocks[inputs], blocks, missing)
    fields = []
    for f in ports["DSW"]:
        fields = [g for g in fields if not (g[1] & f[1])]
        fields.append(f)
    lines, default = [], 0xff
    for name, mask, dflt, settings in fields:
        if not mask & 0xf0:
            continue                       # the EEPROM lines and the two unknown bits
        bm = (mask >> 4) & 0x0f
        default = (default & ~bm) | ((dflt >> 4) & bm)
        if settings is None:
            continue
        bits = [i for i in range(4) if bm & (1 << i)]
        ids = []
        for idx in range(1 << len(bits)):
            v = 0
            for j, b in enumerate(bits):
                if idx & (1 << j):
                    v |= 1 << (b + 4)
            ids.append(settings.get(v, "-"))
        if 2 + len(name) + max(len(i) for i in ids) > OSD_COLS:
            sys.exit(f"dip '{name}' does not fit {OSD_COLS} columns")
        lo, hi = bits[0], bits[-1]
        lines.append(f'        <dip name="{esc(name)}" bits="{lo if lo == hi else f"{lo},{hi}"}" ids="{esc(",".join(ids))}"/>')
    return lines, default


def reversed_guns(text, inputs):
    blocks = ed.blocks(text)
    body = blocks[inputs]
    return bool(re.search(r"LIGHT\d_[XY].*?PORT_REVERSE", body, re.S))


def build(set_name, check_only):
    text = driver()
    g = games(text)[set_name]
    # the build stamp dropped: "Lethal Enforcers (ver UAE, 11/19/92 15:04)" -> "Lethal Enforcers (ver UAE)"
    g["title"] = re.sub(r", \d\d/\d\d/\d\d \d\d:\d\d", "", g["title"])
    rs = romstart(text, set_name)
    zip_names, zip_paths = zips_for(set_name, g["parent"])
    if not zip_paths:
        sys.exit(f"{set_name}: no zip on the ROM path")
    zs = [zipfile.ZipFile(p) for p in zip_paths]
    DL_MAIN, DL_TILES, DL_SPRITES, DL_SPR06, DL_SOUND, DL_SAMPLES, DL_END = dl_map()

    def part(region, i=0):
        name, off, ln, crc = rs[region][i]
        return name, crc, read_crc(zs, name, crc)

    # the regions, from the loaders the frame checks used
    z = rm.rom_zip()
    tiles = rm.load32_word(z, [("191a08", 2), ("191a10", 0), ("191a07", 0x200002), ("191a09", 0x200000)], 0x400000).tobytes()
    spr = rm.load32_word(z, [("191a05", 0), ("191a04", 2), ("191a06", 0x200000)], 0x400000).tobytes()

    lines = []
    stream = bytearray()

    def add_part(name, crc, data, comment=""):
        lines.append(f'        <part name="{esc(name)}" crc="{crc:08x}"/>' + (f"  <!-- {comment} -->" if comment else ""))
        stream.extend(data)

    def add_interleave(group, truth, comment):
        datas = [d for _, _, d in group]
        maps = pick_maps(datas, truth)
        lines.append(f"        <!-- {comment} -->")
        lines.append('        <interleave output="32">')
        for (name, crc, _), m in zip(group, maps):
            lines.append(f'            <part name="{esc(name)}" crc="{crc:08x}" map="{m}"/>')
        lines.append("        </interleave>")
        stream.extend(mra_lib.interleave(list(zip(datas, maps)), 32))

    def at(addr, what):
        if len(stream) != addr:
            sys.exit(f"{set_name}: {what} at {len(stream):#x}, rtl/lethal_sdram.sv expects {addr:#x}")

    at(DL_MAIN, "main")
    add_part(*part("maincpu"), comment="main program")
    at(DL_TILES, "tiles")
    tl = {n: (n, c, read_crc(zs, n, c)) for n, _, _, c in rs["k056832"]}
    add_interleave([tl["191a10"], tl["191a08"]], tiles[:0x200000], "k056832, first half")
    add_interleave([tl["191a09"], tl["191a07"]], tiles[0x200000:], "k056832, second half")
    at(DL_SPRITES, "sprites")
    sl = {n: (n, c, read_crc(zs, n, c)) for n, _, _, c in rs["k053244"]}
    add_interleave([sl["191a05"], sl["191a04"]], spr[:0x200000], "k053244, first half")
    at(DL_SPR06, "191A06")
    a06 = sl["191a06"]
    if bytes(spr[0x200000:]) != bytes(rm.load32_word(z, [("191a06", 0)], 0x200000).tobytes()):
        sys.exit("191A06 is not ROM_LOAD32_WORD at 0x200000")
    add_part(*a06, comment="k053244's second half as the file: the RTL places its words")
    at(DL_SOUND, "sound")
    add_part(*part("soundcpu"), comment="Z80 program")
    at(DL_SAMPLES, "samples")
    add_part(*part("k054539"), comment="054539 samples")
    at(DL_END, "end")

    nv_name, nv_crc, nv = part("eeprom")
    if len(nv) != 128:
        sys.exit(f"{set_name}: EEPROM image is {len(nv)} bytes")
    mod = (1 if g["orient"] == "ORIENTATION_FLIP_X" else 0) | (2 if reversed_guns(text, g["inputs"]) else 0)
    dip_lines, dip_default = dips(text, g["inputs"])
    hs_lines, hs_bytes = hiscore_lines(set_name)

    zip_attr = "|".join(zip_names)
    out = [
        "<misterromdescription>",
        f"    <name>{esc(g['title'])}</name>",
        f"    <setname>{set_name}</setname>",
        f"    <rbf>{RBF}</rbf>",
        f"    <mameversion>{mame_version()}</mameversion>",
        f"    <year>{g['year']}</year>",
        f"    <manufacturer>{esc(g['manufacturer'])}</manufacturer>",
        "    <category>Shooter / Gun</category>",
        "    <rotation>horizontal</rotation>",
        "",
        "    <!-- bit 0: MAME's FLIP_X orientation (else FLIP_Y); bit 1: gun axes reversed -->",
        f'    <rom index="1"><part>{mod:02X}</part></rom>',
        "",
        "    <!-- the download rtl/lethal_sdram.sv expects (its DL_* order); written and",
        "         checked by scripts/build_mra.py -->",
        f'    <rom index="0" zip="{zip_attr}" md5="none" address="0x30000000">',
        *lines,
        "    </rom>",
        "",
        "    <!-- the default EEPROM image (ROM_START's eeprom region) -->",
        f'    <rom index="2" zip="{zip_attr}" md5="none">',
        f'        <part name="{esc(nv_name)}" crc="{nv_crc:08x}"/>',
        "    </rom>",
        "",
        "    <!-- the EEPROM as the game left it: loaded over the default, saved when the",
        "         OSD opens after the game has written it" + ("; then hiscore.v's tables -->" if hs_bytes else " -->"),
        f'    <nvram index="4" size="{128 + hs_bytes}"/>',
        *hs_lines,
        "",
        f'    <switches default="{dip_default:02X}">',
        *dip_lines,
        "    </switches>",
        "",
        f"    <buttons {BUTTONS}/>",
        "</misterromdescription>",
        "",
    ]
    if not dip_lines:
        i = out.index(f'    <switches default="{dip_default:02X}">')
        out[i:i + 2] = [f'    <switches default="{dip_default:02X}"/>']
    xml = "\n".join(out)

    # the parent at the top of releases/, its clones in _alternatives/_<game>/ (RELEASE_PROCESS.md)
    out_dir = OUT_DIR
    if g["parent"] != "0":
        game = re.sub(r"\s*\(.*$", "", games(text)[g["parent"]]["title"])
        out_dir = OUT_DIR / "_alternatives" / f"_{game}"
    out_dir.mkdir(parents=True, exist_ok=True)
    fname = out_dir / (re.sub(r'[<>:"\\|?*]', "", g["title"].replace("/", "-")) + ".mra")
    OUT_DIR.mkdir(exist_ok=True)
    tmp = OUT_DIR / f".{set_name}.mra.tmp"
    tmp.write_text(xml, encoding="utf-8", newline="\n")
    try:
        img = mra_lib.build_image(tmp, [str(p) for p in zip_paths])
        if img != bytes(stream):
            n = next(i for i in range(min(len(img), len(stream))) if img[i] != stream[i]) if len(img) == len(stream) else -1
            sys.exit(f"{set_name}: the .mra's image differs from the stream (first at {n:#x}, sizes {len(img):#x} {len(stream):#x})")
        if mra_lib.mod_byte(tmp) != mod:
            sys.exit(f"{set_name}: mod byte")
        if check_only:
            old = fname.read_text(encoding="utf-8") if fname.exists() else None
            print(f"{set_name}: image {len(img):#x} bytes OK" + ("" if old == xml else f"; {fname.name} differs from what would be written"))
            return old == xml
        fname.write_text(xml, encoding="utf-8", newline="\n")
        print(f"{set_name}: {fname.relative_to(REPO)}  image {len(img):#x} bytes, crc {zlib.crc32(img):08x}, mod {mod:02X}, DIP {dip_default:02X}")
        return True
    finally:
        tmp.unlink()
        for zz in zs:
            zz.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    ok = all([build(s, a.check) for s in (a.sets or SETS)])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
