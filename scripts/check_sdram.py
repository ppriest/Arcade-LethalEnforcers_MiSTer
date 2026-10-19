#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/lethal_sdram.sv end to end: download, then every client port, against MAME's regions.

    JTCORES=<jtcores checkout> python scripts/check_sdram.py [--chunk 4096] [--shifted]

Builds the download stream in rtl/lethal_sdram.sv's order (the DL_* localparams, read
from the RTL), streams the first and last --chunk bytes of every region and the first
--chunk of each half of the tile and sprite regions, then reads back through the four
ports at addresses inside those chunks and compares:
  main      the byte at the address
  tiles     lethal_tilemap's row: first half's 4 bytes then the second half's, byte 0 in 63:56
  sprites   lethal_obj's word: 4 bytes little-endian, then 191A06's 2 bytes
  samples   8 bytes little-endian
Icarus Verilog, with Micron's model from the jtcores checkout (not redistributable).
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import render_model as rm  # noqa: E402
import boot_bench  # noqa: E402


def dl_map():
    src = (REPO / "rtl" / "lethal_sdram.sv").read_text()
    m = dict((k, int(v, 16)) for k, v in re.findall(r"localparam \[24:0\] (DL_\w+)\s*=\s*25'h([0-9a-fA-F]+)", src))
    for k in ("DL_MAIN", "DL_TILES", "DL_SPRITES", "DL_SPR06", "DL_SOUND", "DL_SAMPLES", "DL_END"):
        if k not in m:
            sys.exit(f"{k} missing from rtl/lethal_sdram.sv")
    return m


def regions():
    z = rm.rom_zip()
    main = boot_bench.program_rom("lethalen")
    tiles = rm.load32_word(z, [("191a08", 2), ("191a10", 0), ("191a07", 0x200002), ("191a09", 0x200000)], 0x400000).tobytes()
    spr = rm.load32_word(z, [("191a05", 0), ("191a04", 2), ("191a06", 0x200000)], 0x400000).tobytes()
    snd = z.read("191a02.f4")
    smp = z.read("191a03")
    a06 = z.read("191a06")
    return main, tiles, spr, a06, snd, smp


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chunk", type=int, default=4096)
    ap.add_argument("--shifted", action="store_true", help="the chip's clock 5555 ps late, as on the board")
    a = ap.parse_args()
    jt = os.environ.get("JTCORES")
    if not jt:
        sys.exit("set JTCORES to a jtcores checkout (for Micron's SDRAM model)")
    mt48 = Path(jt) / "modules" / "jtframe" / "hdl" / "ver" / "mt48lc16m16a2.v"
    m = dl_map()
    main_r, tiles, spr, a06, snd, smp = regions()
    C = a.chunk
    d = REPO / "debug" / "sdram_tb"
    d.mkdir(parents=True, exist_ok=True)
    chunks = []          # (stream address, bytes)
    for base, data, cuts in [(m["DL_MAIN"], main_r, [0, len(main_r) - C]),
                             (m["DL_TILES"], tiles, [0, 0x1ff000, 0x200000, len(tiles) - C]),
                             (m["DL_SPRITES"], spr[:0x200000], [0, 0x200000 - C]),
                             (m["DL_SPR06"], a06, [0, len(a06) - C]),
                             (m["DL_SAMPLES"], smp, [0, len(smp) - C])]:
        for o in cuts:
            chunks.append((base + o, data[o:o + C]))
    with open(d / "dl.txt", "w") as f:
        for addr, data in chunks:
            for i, b in enumerate(data):
                f.write(f"{addr + i:x} {b:02x}\n")
    reads, expect = [], []
    for o in list(range(0, C, 37)) + list(range(len(main_r) - C, len(main_r), 41)):
        reads.append((0, o)); expect.append(f"{main_r[o]:02x}")
    for o in list(range(0, C, 64)) + list(range(0x1ff000, 0x1ff000 + C, 96)):
        row = o // 4                               # a row whose both halves were streamed
        if row * 4 + 0x200000 >= 0x200000 + C and row * 4 >= C and o < 0x1ff000:
            continue
        r = tiles[row * 4:row * 4 + 4] + tiles[0x200000 + row * 4:0x200000 + row * 4 + 4]
        if row * 4 >= C and not (0x1ff000 <= row * 4 < 0x1ff000 + C):
            continue
        if not (row * 4 < C):          # second half only streamed for rows < C/4
            continue
        reads.append((1, row)); expect.append(r.hex())
    for row in list(range(0, C // 4, 23)) + list(range((0x200000 - C) // 4, 0x80000, 29)):
        if row >= C // 2 and row * 2 < len(a06) - C:
            continue                               # 191A06's half of this word was not streamed
        w = spr[row * 4:row * 4 + 4] + spr[0x200000 + row * 4:0x200000 + row * 4 + 2]
        v = int.from_bytes(w, "little")
        reads.append((2, row)); expect.append(f"{v:012x}")
    for o in list(range(0, C, 8 * 7)) + list(range(len(smp) - C, len(smp), 8 * 11)):
        g = o // 8
        v = int.from_bytes(smp[g * 8:g * 8 + 8], "little")
        reads.append((3, g)); expect.append(f"{v:016x}")
    (d / "rd.txt").write_text("".join(f"{p} {x:x}\n" for p, x in reads))
    out = d / "out.txt"
    if out.exists():
        out.unlink()
    vvp = d / "tb.vvp"
    files = [REPO / "sim" / "sdram_tb" / "tb_sdram.sv", REPO / "rtl" / "lethal_sdram.sv"] + \
        sorted((REPO / "rtl" / "jtframe" / "sdram").glob("jtframe_sdram64*.v")) + [mt48]
    msys = Path(os.environ.get("MSYS2_ROOT", "E:/msys64")) / "mingw64" / "bin"
    env = dict(os.environ, PATH=str(msys) + os.pathsep + os.environ.get("PATH", ""))
    r = subprocess.run([str(msys / "iverilog.exe"), "-g2012", "-DSIMULATION", "-DSDRAM_SHIFT=0", f"-Ptb_sdram.SHIFTED={int(a.shifted)}", "-o", str(vvp)] + [str(f) for f in files],
                       capture_output=True, text=True, env=env)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    r = subprocess.run([str(msys / "vvp.exe"), "-n", str(vvp), f"+dl={(d / 'dl.txt').as_posix()}", f"+rd={(d / 'rd.txt').as_posix()}",
                        f"+out={out.as_posix()}"], capture_output=True, text=True, env=env)
    print("\n".join(ln for ln in r.stdout.splitlines() if ln.startswith(("DOWNLOADED", "READ", "TIMEOUT", "downloaded", "DL_WAIT"))))
    got = out.read_text().split("\n") if out.exists() else []
    got = [g.split() for g in got if g.strip()]
    bad = 0
    names = ["main", "tiles", "sprites", "samples"]
    from collections import Counter
    tot, ok = Counter(), Counter()
    for (p, x), e, g in zip(reads, expect, got):
        tot[names[p]] += 1
        if g[2].lower() == e.lower():
            ok[names[p]] += 1
        elif bad < 6:
            print(f"  {names[p]} {x:#x}: got {g[2]} expected {e}")
            bad += 1
    print(" ".join(f"{k} {ok[k]}/{tot[k]}" for k in names), f"(reads answered {len(got)} of {len(reads)})")
    return 0 if all(ok[k] == tot[k] for k in names) and len(got) == len(reads) else 1


if __name__ == "__main__":
    sys.exit(main())
