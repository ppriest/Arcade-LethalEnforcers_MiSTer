#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/lethal_tilemap.sv against the software model, on MAME captures.

    python scripts/check_tilemap.py lethalen-f2400 [more captures] [--romlat 3] [--rev]

For each capture: writes the bench inputs to debug/<capture>/tb_tilemap/, runs
sim/tilemap_tb (Verilator), and compares every layer pixel of bitmap lines
16..239 with render_model.draw_layer: transparency, and the pen
1024 * PCU bank + 64 * { colour, 00 } + pixel. Prints mismatches per layer.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import render_model as rm  # noqa: E402

PAGES = (0, 1, 4, 5, 16)


def rom_rows_hex(path):
    if path.exists():
        return
    z = rm.rom_zip()
    reg = rm.load32_word(z, [("191a08", 2), ("191a10", 0), ("191a07", 0x200002), ("191a09", 0x200000)],
                         0x400000)
    a = reg[:0x200000].reshape(-1, 4)          # row r: bytes 4r..4r+3 = code * 32 + y * 4
    b = reg[0x200000:].reshape(-1, 4)
    rows = np.concatenate([a, b], axis=1)       # first half's bytes, then the second's
    with open(path, "w") as f:
        for r in rows:
            f.write(r.tobytes().hex() + "\n")


def bench_inputs(cap, d):
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "vram.txt", "w") as f:
        for p in PAGES:
            words = cap.vram[p * 0x1000:(p + 1) * 0x1000].astype(int)
            attr, code = words[0::2], words[1::2]
            for t in range(2048):
                f.write(f"{p} 0 {t} {code[t] & 0xff:02x}\n{p} 1 {t} {code[t] >> 8:02x}\n"
                        f"{p} 2 {t} {attr[t] & 0xff:02x}\n{p} 3 {t} {attr[t] >> 8:02x}\n")
    with open(d / "regs.txt", "w") as f:
        for v in cap.regs:
            f.write(f"{int(v):04x}\n")


def model_layers(cap):
    layer_base, _, _ = rm.colorbases(cap)
    return [rm.draw_layer(cap, l, layer_base[l]) for l in range(4)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="+")
    ap.add_argument("--romlat", type=int, default=3)
    ap.add_argument("--rev", action="store_true")
    a = ap.parse_args()
    romhex = REPO / "debug" / "roms" / "tiles_rows.hex"
    romhex.parent.mkdir(parents=True, exist_ok=True)
    rom_rows_hex(romhex)
    bash = shutil.which("bash") or "bash"
    rc = 0
    for name in a.capture:
        cap = rm.Capture(name)
        d = cap.dir / "tb_tilemap"
        bench_inputs(cap, d)
        out = d / "rtl_layers.txt"
        r = subprocess.run([bash, "scripts/run_verilator.sh", "tilemap_tb",
                            f"+vram={(d / 'vram.txt').as_posix()}", f"+regs={(d / 'regs.txt').as_posix()}",
                            f"+rom={romhex.as_posix()}", f"+out={out.as_posix()}",
                            f"+romlat={a.romlat}", f"+rev={1 if a.rev else 0}"],
                           cwd=REPO, capture_output=True, text=True)
        info = [ln for ln in (r.stdout + r.stderr).splitlines() if ln.startswith(("LINES", "UNSUPP", "%Error", "need"))]
        if not out.exists():
            print(f"{name}: bench produced nothing\n" + (r.stdout + r.stderr)[-3000:])
            rc = 1
            continue
        rtl = np.zeros((4, rm.BMP_H, 288), dtype=int)
        for ln in out.read_text().splitlines():
            f = ln.split()
            y, l = int(f[0]), int(f[1])
            rtl[l, y] = [int(v, 16) for v in f[2:]]
        if a.rev:
            rtl = rtl[:, :, ::-1]
        layer_base, _, _ = rm.colorbases(cap)
        model = model_layers(cap)
        bad = []
        for l in range(4):
            mv = model[l][16:240, 24:312]
            rv = rtl[l, 16:240]
            pix = rv & 0xff
            pen = np.where(pix != 0, 16 * ((layer_base[l] + ((rv >> 8) << 4)) % 1024) + pix, 0)
            nbad = int((pen != mv).sum())
            bad.append(nbad)
            if nbad:
                ys, xs = np.nonzero(pen != mv)
                print(f"  layer {l}: first at bitmap ({xs[0] + 24}, {ys[0] + 16}): RTL {pen[ys[0], xs[0]]:04x} "
                      f"model {mv[ys[0], xs[0]]:04x}")
        print(f"{name}: layer mismatches {bad} of {224 * 288} each; " + "; ".join(info))
        rc |= any(bad)
    return rc


if __name__ == "__main__":
    sys.exit(main())
