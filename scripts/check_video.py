#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/lethal_video.sv, the whole video top, against MAME's screenshots.

    python scripts/check_video.py [captures...] [--romlat 9] [--dx 105]

Needs the inputs the block benches write (scripts/check_tilemap.py, check_obj.py,
check_frame.py) in debug/<capture>/. Runs sim/video_tb with the set's orientation,
which logs a frame in display order, and compares it with reference.png. Differing
pixels are attributed as scripts/check_frame.py does (zoomed sprite, RTL-only sprite,
shadow edge, other), after mapping display pixels back to MAME's bitmap.
"""
import argparse
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
import check_frame as cf  # noqa: E402
import classify_obj as cl  # noqa: E402


def run(cap, romlat, dx):
    d = cap.dir
    out = d / "tb_video" / "frame.txt"
    out.parent.mkdir(exist_ok=True)
    if out.exists():
        out.unlink()
    orient = 2 if rm.ORIENT.get(cap.set, "flipy") == "flipx" else 1
    bash = shutil.which("bash") or "bash"
    args = [bash, "scripts/run_verilator.sh", "video_tb", f"-GOBJ_DX={dx}",
            f"+vram={(d / 'tb_tilemap' / 'vram.txt').as_posix()}", f"+regs={(d / 'tb_tilemap' / 'regs.txt').as_posix()}",
            f"+tiles={(REPO / 'debug' / 'roms' / 'tiles_rows.hex').as_posix()}",
            f"+ram={(d / 'tb_obj' / 'ram.txt').as_posix()}", f"+oregs={(d / 'tb_obj' / 'regs.txt').as_posix()}",
            f"+sprites={(REPO / 'debug' / 'roms' / 'sprites6.hex').as_posix()}",
            f"+pal={(d / 'tb_mixer' / 'pal.txt').as_posix()}", f"+pcu={(d / 'tb_mixer' / 'pcu.txt').as_posix()}",
            f"+orient={orient}", f"+romlat={romlat}", f"+out={out.as_posix()}"]
    r = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
    if not out.exists():
        sys.exit(f"{cap.dir.name}: bench produced nothing\n{(r.stdout + r.stderr)[-3000:]}")
    v = np.array([int(x, 16) for x in out.read_text().split()], dtype=np.int64)
    if len(v) != 224 * 288:
        sys.exit(f"{cap.dir.name}: {len(v)} pixels logged")
    v = v.reshape(224, 288)
    info = [ln for ln in (r.stdout + r.stderr).splitlines() if ln.startswith("FRAME")]
    return np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], axis=2).astype(np.uint8), info


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="*")
    ap.add_argument("--romlat", type=int, default=9)
    ap.add_argument("--dx", type=int, default=105)
    a = ap.parse_args()
    names = a.capture or [d.name for d in sorted((REPO / "debug").glob("lethal*-f*"))
                          if (d / "tb_mixer" / "pal.txt").exists()]
    total = Counter()
    for n in names:
        cap = rm.Capture(n)
        img, info = run(cap, a.romlat, a.dx)
        diff = np.any(img != cap.ref, axis=2)
        flipy = rm.ORIENT.get(cap.set, "flipy") == "flipy"
        dmap = diff[::-1, :] if flipy else diff[:, ::-1]          # display -> bitmap window
        _, _, owner, zoomed, _ = cl.model_with_owner(cap)
        w = (slice(rm.VIS_Y0, rm.VIS_Y1 + 1), slice(rm.VIS_X0, rm.VIS_X1 + 1))
        own = owner[w]
        mshd = co.model_sprites(cap)[2][w]
        obj = cf.load_obj(cap)[w]
        rspr = (obj & 0x803f) != 0
        rshd = (obj >> 15) & 1 == 1
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
        Image.fromarray(np.concatenate([img, cap.ref, np.where(diff[:, :, None], np.array([255, 0, 255], np.uint8),
                                                               cap.ref // 3)], axis=1)).save(cap.dir / "tb_video" / "cmp.png")
        print(f"{n:24s} {int(diff.sum()):6d} differ: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items()))
              + ("; " + info[0] if info else ""))
    print("ALL " + ", ".join(f"{k} {v}" for k, v in sorted(total.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
