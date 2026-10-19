#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The whole board from reset (sim/system_tb) against MAME.

    python scripts/check_system.py <set> --trace 14500000          # main CPU bus vs MAME's boot trace
    python scripts/check_system.py <set> --frames 1199,1201        # frames vs a capture's reference

--trace: compares with debug/<set>-boot/<set>_boot.trace (scripts/mame_boot_trace.py)
through scripts/compare_boot_trace.py: writes in order, non-ROM reads in order, ROM reads
as a superset. Nothing is replayed: every peripheral is the RTL's.
--frames a,b: logs display frames a..b (counted in vblank IRQs from reset) and compares
each with debug/<set>-f<N>/reference.png for N in --capture-frames (default: the
captures that exist for the set), reporting the best match per capture.
"""
import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import boot_bench  # noqa: E402
import render_model as rm  # noqa: E402


def write_hex(path, data):
    path.write_text("\n".join(f"{b:02x}" for b in data) + "\n")


def inputs(game):
    d = REPO / "debug" / "system" / game
    d.mkdir(parents=True, exist_ok=True)
    write_hex(d / "prog.hex", boot_bench.program_rom(game))
    z = rm.rom_zip()
    write_hex(d / "snd.hex", z.read("191a02.f4"))
    smp = z.read("191a03")
    # an 8-byte granule a line, byte 0 in the low bits
    lines = [smp[i:i + 8][::-1].hex() for i in range(0, len(smp), 8)]
    (d / "smp.hex").write_text("\n".join(lines) + "\n")
    nv = boot_bench.PROGRAM[game].replace(".u4", "")
    names = [n for n in z.namelist() if n.endswith(".nv") and (n.startswith(game + "/") or n == {"lethalen": "lethalenue.nv"}.get(game))]
    write_hex(d / "nv.hex", z.read(names[0]))
    return d


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("--trace", type=int, default=0)
    ap.add_argument("--frames", default="")
    ap.add_argument("--romlat", type=int, default=3)
    ap.add_argument("--coin", type=int, default=-1, help="RTL frame of the coins (scripts/mame/audio_play.lua)")
    ap.add_argument("--audio", type=int, default=0, help="log the audio from reset to this vblank count (debug/system/<set>/audio.txt)")
    a = ap.parse_args()
    d = inputs(a.game)
    orient = 2 if rm.ORIENT.get(a.game, "flipy") == "flipx" else 1
    args = [shutil.which("bash") or "bash", "scripts/run_verilator.sh", "system_tb",
            f"+prog={(d / 'prog.hex').as_posix()}", f"+snd={(d / 'snd.hex').as_posix()}",
            f"+tiles={(REPO / 'debug' / 'roms' / 'tiles_rows.hex').as_posix()}",
            f"+sprites={(REPO / 'debug' / 'roms' / 'sprites6.hex').as_posix()}",
            f"+nv={(d / 'nv.hex').as_posix()}", f"+orient={orient}", f"+romlat={a.romlat}",
            f"+smp={(d / 'smp.hex').as_posix()}"]
    if a.audio:
        args += [f"+audio={(d / 'audio.txt').as_posix()}", f"+until={a.audio}"]
    if a.coin >= 0:
        args += [f"+coin={a.coin}"]
    base = REPO / "debug" / f"{a.game}-boot"
    if a.trace:
        args += [f"+trace={(base / f'{a.game}_rtl.trace').as_posix()}", f"+n={a.trace}"]
    if a.frames:
        args += [f"+frames={a.frames}", f"+out={(d / 'frames.txt').as_posix()}"]
    r = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
    print("\n".join(ln for ln in (r.stdout + r.stderr).splitlines() if ln.startswith(("DONE", "%Error", "missing", "frame "))))
    rc = 0
    if a.trace:
        rc |= subprocess.run([sys.executable, "scripts/compare_boot_trace.py", "compare", a.game], cwd=REPO).returncode
    if a.frames:
        fa, fb = map(int, a.frames.split(","))
        v = np.array([int(x, 16) for x in (d / "frames.txt").read_text().split()], dtype=np.int64)
        n = len(v) // (224 * 288)
        frames = v[:n * 224 * 288].reshape(n, 224, 288)
        imgs = np.stack([(frames >> 16) & 255, (frames >> 8) & 255, frames & 255], axis=3).astype(np.uint8)
        caps = sorted((REPO / "debug").glob(f"{a.game}-f*"))
        for c in caps:
            if "_play" in c.name:
                continue
            ref = np.asarray(Image.open(c / "reference.png").convert("RGB"))
            scores = [(int(np.any(imgs[i] != ref, axis=2).sum()), fa + i) for i in range(n)]
            best = min(scores)
            print(f"{c.name}: best RTL frame {best[1]} ({best[0]} pixels differ)")
            if best[1] == fa + scores.index(best):
                Image.fromarray(np.concatenate([imgs[scores.index(best)], ref], axis=1)).save(d / f"{c.name}_cmp.png")
    return rc


if __name__ == "__main__":
    sys.exit(main())
