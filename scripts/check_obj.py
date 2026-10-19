#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/lethal_obj.sv (jt053244 at 6 bpp) against the model's sprites.

    python scripts/check_obj.py <capture> [...] [--romlat 3] [--dx N --dy N]

jt053244 is the chip modelled from the silicon, not MAME's k053244, so this
MEASURES the difference rather than asserting none. Per capture: the sprite
layer drawn alone (no tiles, so every priority mask passes) by
render_sprites.draw_sprites, against the bench's frame. The RTL's raster
(vdump 0x110..0x1ef, hdump 0x20..0x19f) is placed on MAME's bitmap with one
shift; without --dx/--dy the shift that best aligns the opaque pixels of all
each capture is found by correlation and printed.

Reported per capture, at that shift, over the visible window:
  opaque   pixels opaque in both / only in the model / only in the RTL
  value    of those opaque in both, how many have the same pen and colour
  shadow   pixels shadowed in both / only model / only RTL
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
import render_sprites as rs  # noqa: E402


def rom_hex(path):
    if path.exists():
        return
    z = rm.rom_zip()
    reg = rm.load32_word(z, [("191a05", 0), ("191a04", 2), ("191a06", 0x200000)], 0x400000)
    a = reg[:0x200000].reshape(-1, 4).astype(np.uint64)
    b = reg[0x200000:].reshape(-1, 4).astype(np.uint64)
    w = a[:, 0] | (a[:, 1] << 8) | (a[:, 2] << 16) | (a[:, 3] << 24) | (b[:, 0] << 32) | (b[:, 1] << 40)
    with open(path, "w") as f:
        for v in w:
            f.write(f"{int(v):012x}\n")


def model_sprites(cap):
    _, sb, _ = rm.colorbases(cap)
    pens = np.zeros((rm.BMP_H, rm.BMP_W), int)
    prio = np.zeros_like(pens)
    rs.draw_sprites(cap, pens, prio, sb)
    pen = pens & 0x1fff
    shadow = (pens & 0x2000) != 0
    col = (pen >> 6) - sb
    pix = pen & 63
    return pix, col, shadow


def run_bench(cap, romhex, romlat):
    d = cap.dir / "tb_obj"
    d.mkdir(exist_ok=True)
    (d / "ram.txt").write_text("".join(f"{b:02x}\n" for b in cap.objbuf))
    (d / "regs.txt").write_text("".join(f"{b:02x}\n" for b in cap.objregs))
    out = d / "rtl_frame.txt"
    if out.exists():
        out.unlink()
    bash = shutil.which("bash") or "bash"
    r = subprocess.run([bash, "scripts/run_verilator.sh", "obj_tb", f"+ram={(d / 'ram.txt').as_posix()}",
                        f"+regs={(d / 'regs.txt').as_posix()}", f"+rom={romhex.as_posix()}",
                        f"+out={out.as_posix()}", f"+romlat={romlat}"], cwd=REPO, capture_output=True, text=True)
    if not out.exists():
        sys.exit(f"{cap.dir.name}: bench produced nothing\n{(r.stdout + r.stderr)[-3000:]}")
    frame = {}
    for ln in out.read_text().splitlines():
        f = ln.split()
        frame[int(f[0], 16)] = [int(v, 16) for v in f[1:]]
    arr = np.zeros((0x200, 0x1a0), int)          # [vdump][hdump]
    for v, row in frame.items():
        arr[v, 0x20:0x20 + len(row)] = row
    return arr


def place(arr, dx, dy):
    """RTL pixels on MAME's bitmap: bitmap (x, y) <- raster (hdump x + dx, vdump y + dy)."""
    out = np.zeros((rm.BMP_H, rm.BMP_W), int)
    for y in range(rm.VIS_Y0, rm.VIS_Y1 + 1):
        v = y + dy
        if 0 <= v < arr.shape[0]:
            for_x = np.arange(rm.VIS_X0, rm.VIS_X1 + 1)
            h = for_x + dx
            ok = (h >= 0) & (h < arr.shape[1])
            out[y, for_x[ok]] = arr[v, h[ok]]
    return out


def best_shift(cap_model, arr):
    """The shift maximising the overlap of opaque pixels, by FFT correlation."""
    pix = cap_model[0]
    M = (pix != 0).astype(float)
    R = ((arr & 63) != 0).astype(float)
    if not M.any() or not R.any():
        return (103, 255)
    H = W = 1024
    c = np.fft.irfft2(np.conj(np.fft.rfft2(M, (H, W))) * np.fft.rfft2(R, (H, W)), (H, W))
    dy, dx = np.unravel_index(np.argmax(c), c.shape)
    return (int(dx if dx < W // 2 else dx - W), int(dy if dy < H // 2 else dy - H))


def score(cap_model, arr, dx, dy):
    pix, col, shadow = cap_model
    p = place(arr, dx, dy)
    win = (slice(rm.VIS_Y0, rm.VIS_Y1 + 1), slice(rm.VIS_X0, rm.VIS_X1 + 1))
    rpix = (p & 63)[win]
    rcol = ((p >> 6) & 0x7f)[win]
    rshd = ((p >> 15) & 1)[win] != 0
    mpix, mcol, mshd = pix[win], col[win], shadow[win]
    mo, ro = mpix != 0, rpix != 0
    both = mo & ro
    same = both & (mpix == rpix) & ((mcol & 0xf) == (rcol & 0xf))
    return dict(both=int(both.sum()), model_only=int((mo & ~ro).sum()), rtl_only=int((ro & ~mo).sum()),
                same=int(same.sum()), shd_both=int((mshd & rshd).sum()),
                shd_model=int((mshd & ~rshd).sum()), shd_rtl=int((rshd & ~mshd).sum()))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="+")
    ap.add_argument("--romlat", type=int, default=3)
    ap.add_argument("--dx", type=int)
    ap.add_argument("--dy", type=int)
    a = ap.parse_args()
    romhex = REPO / "debug" / "roms" / "sprites6.hex"
    romhex.parent.mkdir(parents=True, exist_ok=True)
    rom_hex(romhex)
    runs = []
    for name in a.capture:
        cap = rm.Capture(name)
        runs.append((name, model_sprites(cap), run_bench(cap, romhex, a.romlat)))
    shifts = {}
    for name, m, arr in runs:
        shifts[name] = (a.dx, a.dy) if a.dx is not None and a.dy is not None else best_shift(m, arr)
    for name, m, arr in runs:
        dx, dy = shifts[name]
        s = score(m, arr, dx, dy)
        tot_m = s["both"] + s["model_only"]
        print(f"{name}: shift ({dx:+d}, {dy:+d}); opaque both {s['both']} model-only {s['model_only']} rtl-only {s['rtl_only']}"
              f" (of {tot_m} model pixels); same value {s['same']}; shadow both {s['shd_both']}"
              f" model-only {s['shd_model']} rtl-only {s['shd_rtl']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
