#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Whole frames from the RTL against MAME: lethal_tilemap + lethal_obj + lethal_mixer.

    python scripts/check_frame.py [captures...]      (default: every capture with both bench outputs)

Takes the tilemap bench's layers (debug/<c>/tb_tilemap/rtl_layers.txt, from
scripts/check_tilemap.py) and the sprite bench's frame (debug/<c>/tb_obj/rtl_frame.txt,
from scripts/check_obj.py, placed at bitmap = raster + (105, 255)), runs them through
sim/mixer_tb, applies MAME's orientation, and compares with reference.png. Every
differing pixel is attributed to the model sprite drawn there (scripts/classify_obj.py):
  zoomed     a zoomed sprite's pixel: jt053244's zoom, recorded in MAME_KLUDGES.md
  rtl-sprite no model sprite, but the RTL's sprite layer has a pixel there
  shadow     the model and the RTL disagree on whether the pixel is shadowed: the edge of a
             zoomed shadow sprite (the only shadow sprites in the captures are zoomed)
  other      anything else -- the mixer, the tiles or the palette
"""
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import render_model as rm  # noqa: E402
import check_obj as co  # noqa: E402
import classify_obj as cl  # noqa: E402


def load_layers(cap):
    rtl = np.zeros((4, rm.BMP_H, 288), dtype=int)
    for ln in (cap.dir / "tb_tilemap" / "rtl_layers.txt").read_text().splitlines():
        f = ln.split()
        rtl[int(f[1]), int(f[0])] = [int(v, 16) for v in f[2:]]
    return rtl


def load_obj(cap):
    arr = np.zeros((0x200, 0x1a0), int)
    for ln in (cap.dir / "tb_obj" / "rtl_frame.txt").read_text().splitlines():
        f = ln.split()
        arr[int(f[0], 16), 0x20:0x20 + 384] = [int(v, 16) for v in f[1:]]
    return co.place(arr, cl.DX, cl.DY)


def main():
    names = sys.argv[1:] or [d.name for d in sorted((REPO / "debug").glob("lethal*-f*"))
                             if (d / "tb_tilemap" / "rtl_layers.txt").exists()
                             and (d / "tb_obj" / "rtl_frame.txt").exists()]
    bash = shutil.which("bash") or "bash"
    total = Counter()
    for n in names:
        cap = rm.Capture(n)
        lay = load_layers(cap)
        obj = load_obj(cap)
        d = cap.dir / "tb_mixer"
        d.mkdir(exist_ok=True)
        with open(d / "pix.txt", "w") as f:
            for y in range(rm.VIS_Y0, rm.VIS_Y1 + 1):
                for x in range(288):
                    f.write(f"{lay[0, y, x]:03x} {lay[1, y, x]:03x} {lay[2, y, x]:03x} {lay[3, y, x]:03x} "
                            f"{obj[y, rm.VIS_X0 + x]:04x}\n")
        (d / "pal.txt").write_text("".join(f"{b:02x}\n" for b in cap.palraw))
        (d / "pcu.txt").write_text("".join(f"{b:02x}\n" for b in cap.ctrl[1:4]))
        out = d / "rgb.txt"
        if out.exists():
            out.unlink()
        r = subprocess.run([bash, "scripts/run_verilator.sh", "mixer_tb", f"+pix={(d / 'pix.txt').as_posix()}",
                            f"+pal={(d / 'pal.txt').as_posix()}", f"+pcu={(d / 'pcu.txt').as_posix()}",
                            f"+out={out.as_posix()}"], cwd=REPO, capture_output=True, text=True)
        if not out.exists():
            sys.exit(f"{n}: bench produced nothing\n{(r.stdout + r.stderr)[-3000:]}")
        v = np.array([int(x, 16) for x in out.read_text().split()], dtype=np.int64).reshape(224, 288)
        img = np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], axis=2).astype(np.uint8)
        vis = img[::-1, :] if rm.ORIENT.get(cap.set, "flipy") == "flipy" else img[:, ::-1]
        diff = np.any(vis != cap.ref, axis=2)
        # back to bitmap coordinates for the attribution
        dmap = diff[::-1, :] if rm.ORIENT.get(cap.set, "flipy") == "flipy" else diff[:, ::-1]
        _, _, owner, zoomed, _ = cl.model_with_owner(cap)
        own = owner[rm.VIS_Y0:rm.VIS_Y1 + 1, rm.VIS_X0:rm.VIS_X1 + 1]
        rspr = (obj[rm.VIS_Y0:rm.VIS_Y1 + 1, rm.VIS_X0:rm.VIS_X1 + 1] & 0x803f) != 0
        mshd = co.model_sprites(cap)[2][rm.VIS_Y0:rm.VIS_Y1 + 1, rm.VIS_X0:rm.VIS_X1 + 1]
        rshd = (obj[rm.VIS_Y0:rm.VIS_Y1 + 1, rm.VIS_X0:rm.VIS_X1 + 1] >> 15) & 1 == 1
        c = Counter()
        for y, x in zip(*np.nonzero(dmap)):
            o = own[y, x]
            if o >= 0:
                c["zoomed" if zoomed[o] else "unzoomed-sprite"] += 1
            elif mshd[y, x] != rshd[y, x]:
                c["shadow"] += 1
            elif rspr[y, x]:
                c["rtl-sprite"] += 1
            else:
                c["other"] += 1
        total.update(c)
        Image.fromarray(np.concatenate([vis, cap.ref, np.where(diff[:, :, None], np.array([255, 0, 255], np.uint8),
                                                               cap.ref // 3)], axis=1)).save(d / "frame_cmp.png")
        print(f"{n:24s} {int(diff.sum()):6d} of 64512 differ: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items())))
    print("ALL " + ", ".join(f"{k} {v}" for k, v in sorted(total.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
