#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's 054539 (scripts/k054539_model.py, KonamiGX 9e3f95e) on a MAME write log, as a
third opinion beside MAME's WAV and the RTL (scripts/check_k539.py's files).

    python scripts/k539_model.py lethalen [--phase 1] [--from S --to S]

Applies debug/k539/<set>/mame.k539 (writes, 0x22d reads, 054321 volume) sample by sample,
with lethal.cpp's routing and sound.cpp's int() truncation, and reports how the model's
output compares with MAME's WAV (lag -541) and with the RTL's rtl_phase<n>.txt.
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import compare_audio as ca      # noqa: E402
import k054539_model as km      # noqa: E402
import render_model as rm       # noqa: E402

LAG = -541                      # MAME's WAV starts this many samples after machine time 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--phase", type=int, default=1)
    a = ap.parse_args()
    d = REPO / "debug" / "k539" / a.set
    events = []
    for ln in open(d / "mame.k539"):
        t, s, r, v = ln.split()
        events.append((int(s), t, int(r, 16), int(v, 16)))
    mame, _ = ca.load_wav(d / "mame.wav")
    rtl = np.loadtxt(d / f"rtl_phase{a.phase}.txt", dtype=np.int64).reshape(-1, 2)
    n = len(rtl)
    chip = km.Chip(rm.rom_zip().read("191a03"))
    active, vol = 0, 0
    out = np.zeros((n, 2), dtype=np.int64)
    ei = 0
    for k in range(n):
        while ei < len(events) and events[ei][0] + (a.phase if events[ei][1] != "V" else 0) <= k:
            s, t, r, v = events[ei]
            if t == "W":
                chip.write(r, v)
            elif t == "R":
                chip.read(r)
            else:
                active, vol = r, v
            ei += 1
        lval, rval = chip.sample()
        g = 2.0 ** ((vol - 40) / 10.0)
        left = rval * g if active & 2 else 0.0
        right = lval * g if active & 1 else 0.0
        out[k] = [max(-32768, min(32767, int(left))), max(-32768, min(32767, int(right)))]
    lo, hi = max(0, -LAG), min(n, len(mame) - LAG)
    for name, other in (("MAME", mame[lo + LAG:hi + LAG]), ("RTL", rtl[lo:hi])):
        x = out[lo:hi]
        snd = np.any(x != 0, axis=1) | np.any(other != 0, axis=1)
        dd = np.abs(x - other).max(axis=1)[snd]
        print(f"model vs {name}: {snd.sum()} samples with sound, exact {np.mean(dd == 0) * 100:.2f}%, "
              f"within 1 {np.mean(dd <= 1) * 100:.2f}%, max {dd.max()}")
        bad = np.nonzero((np.abs(x - other).max(axis=1) > 1))[0]
        if len(bad):
            print(f"   >1 off: {len(bad)} samples, seconds {sorted(set((bad + lo) // 48000))}")
    np.savetxt(d / f"model_phase{a.phase}.txt", out, fmt="%d")


if __name__ == "__main__":
    main()
