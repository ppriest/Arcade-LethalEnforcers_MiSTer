#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Where jt053244 (sim/obj_tb) differs from MAME's sprites, and why.

    python scripts/classify_obj.py [captures...]      (default: every debug/lethal*-f* capture)

Reads each capture's last bench frame (debug/<capture>/tb_obj/rtl_frame.txt, written by
scripts/check_obj.py) at the core's fixed shift, bitmap = raster + (105, 255), and the
model's sprites with the sprite that drew each pixel. Every visible sprite pixel is one of:
  same       opaque in both, same pen and colour
  differ     opaque in both, different pen or colour
  model-only / rtl-only
and each is attributed to the model sprite drawn there, classed as
  zoomed     zoom X or Y not 0x40
  unzoomed
Pixels only the RTL draws have no model sprite and are counted on their own.
"""
import sys
from collections import Counter
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import render_model as rm  # noqa: E402
import render_sprites as rs  # noqa: E402
import check_obj as co  # noqa: E402

DX, DY = 105, 255


def model_with_owner(cap):
    """The model's sprite layer and, per pixel, the buffer offset of the sprite that drew it."""
    _, sb, _ = rm.colorbases(cap)
    pens = np.zeros((rm.BMP_H, rm.BMP_W), int)
    prio = np.zeros_like(pens)
    owner = np.full((rm.BMP_H, rm.BMP_W), -1, int)
    current = {"offs": -1}
    orig_blit = rs.blit

    def blit(pens_, prio_, *a):
        before = prio_.copy()
        orig_blit(pens_, prio_, *a)
        owner[(prio_ == 31) & (before != 31)] = current["offs"]

    buf = rs.buffer_words(cap)
    zoomed = {}
    for offs in range(0, 0x400, 8):
        zx = buf[offs + 5] if (buf[offs] & 0x4000) == 0 else buf[offs + 4]
        zoomed[offs] = buf[offs + 4] != 0x40 or zx != 0x40

    # draw_sprites walks the sorted list; record which entry each blit belongs to
    orig_cb = rs.lethal_callback
    order = []

    def cb(code, color, base):
        return orig_cb(code, color, base)

    rs.blit = blit
    # replay draw_sprites' sort to know the drawing order
    sortedlist = [-1] * 128
    for offs in range(0, 0x400, 8):
        pc = buf[offs]
        if pc & 0x8000:
            pc &= 0x7f
            if offs and pc == 0:
                continue
            if sortedlist[pc] == -1:
                sortedlist[pc] = offs
    order = [sortedlist[pc] for pc in range(127, -1, -1) if sortedlist[pc] != -1]
    it = iter(order)
    orig_lc = rs.lethal_callback

    def lc(code, color, base):
        current["offs"] = next(it)
        return orig_lc(code, color, base)

    rs.lethal_callback = lc
    try:
        rs.draw_sprites(cap, pens, prio, sb)
    finally:
        rs.blit = orig_blit
        rs.lethal_callback = orig_lc
    # duplicates: entries with a priority code another, earlier entry already took
    seen, dup = set(), set()
    for offs in range(0, 0x400, 8):
        if buf[offs] & 0x8000:
            pc = buf[offs] & 0x7f
            if pc in seen:
                dup.add(offs)
            seen.add(pc)
    return pens, sb, owner, zoomed, dup


def main():
    names = sys.argv[1:] or [d.name for d in sorted((REPO / "debug").glob("lethal*-f*"))
                             if (d / "tb_obj" / "rtl_frame.txt").exists()]
    total = Counter()
    for n in names:
        cap = rm.Capture(n)
        pens, sb, owner, zoomed, dup = model_with_owner(cap)
        arr = np.zeros((0x200, 0x1a0), int)
        for ln in (cap.dir / "tb_obj" / "rtl_frame.txt").read_text().splitlines():
            f = ln.split()
            arr[int(f[0], 16), 0x20:0x20 + 384] = [int(v, 16) for v in f[1:]]
        p = co.place(arr, DX, DY)
        w = (slice(rm.VIS_Y0, rm.VIS_Y1 + 1), slice(rm.VIS_X0, rm.VIS_X1 + 1))
        mpen = (pens & 0x1fff)[w]
        mpix, mcol = mpen & 63, (mpen >> 6) - sb
        rpix, rcol = (p & 63)[w], ((p >> 6) & 0x7f)[w]
        own = owner[w]
        c = Counter()
        for y, x in zip(*np.nonzero((mpix != 0) | (rpix != 0))):
            mo, ro = mpix[y, x] != 0, rpix[y, x] != 0
            if mo and ro:
                kind = "same" if (mpix[y, x] == rpix[y, x] and (mcol[y, x] & 15) == (rcol[y, x] & 15)) else "differ"
            else:
                kind = "model-only" if mo else "rtl-only"
            o = own[y, x]
            cls = "none" if o < 0 else ("duplicate" if o in dup else ("zoomed" if zoomed[o] else "unzoomed"))
            c[(kind, cls)] += 1
        total.update(c)
        print(f"{n:24s} " + ", ".join(f"{k}/{cl} {v}" for (k, cl), v in sorted(c.items())))
    print("\nALL " + ", ".join(f"{k}/{cl} {v}" for (k, cl), v in sorted(total.items())))


if __name__ == "__main__":
    main()
