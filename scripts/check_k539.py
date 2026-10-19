#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/sound/lethal_k539.sv against MAME's audio, from MAME's own register writes.

    python scripts/check_k539.py lethalen [--frames 1200] [--coin 400] [--phase 0 1]

One MAME run (scripts/mame/k539_writes.lua with -wavwrite, coins and Start as
scripts/mame/audio_play.lua) gives the Z80's writes to the 054539 with their sample times
and the audio. sim/k539_tb plays the writes into the RTL, and the two are compared over
the samples with sound: exact, within 1. MAME's speaker effects are off for the capture
(scripts/mame/cfg_noeffects): its default high-pass and EQ change the recorded samples. --phase tries where a write logged
at sample s lands (before sample s + phase).
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths  # noqa: E402
import compare_audio as ca  # noqa: E402
import render_model as rm  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", type=int, default=1200)
    ap.add_argument("--coin", type=int, default=400)
    ap.add_argument("--phase", type=int, nargs="+", default=[0, 1])
    a = ap.parse_args()
    d = REPO / "debug" / "k539" / a.set
    d.mkdir(parents=True, exist_ok=True)
    wav, wr = d / "mame.wav", d / "mame.k539"
    mame_dir, exe = mame_paths()
    # MAME's speaker effects off (its default high-pass and EQ change the recorded samples)
    with tempfile.TemporaryDirectory() as nv, tempfile.TemporaryDirectory() as cfg:
        shutil.copy(REPO / "scripts" / "mame" / "cfg_noeffects" / "default.cfg", cfg)
        env = dict(os.environ, **lua_runner_env("k539_writes.lua"), CORE_FRAMES=str(a.frames),
                   LC_COIN=str(a.coin), CORE_OUT=wr.as_posix())
        cmd = mame_cmd(exe, a.set, "k539_writes.lua", mame_dir,
                       ["-nvram_directory", nv, "-cfg_directory", cfg,
                        "-wavwrite", str(wav), "-samplerate", "48000"])
        r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True,
                           timeout=3600, **NO_WINDOW)
    if "CORE_CAPTURE_OK" not in r.stdout:
        sys.exit(f"MAME run failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    mame, _ = ca.load_wav(wav)
    smp = rm.rom_zip().read("191a03")
    (d / "smp.hex").write_text("\n".join(smp[i:i + 8][::-1].hex() for i in range(0, len(smp), 8)) + "\n")
    nz = np.nonzero(np.any(mame != 0, axis=1))[0]
    print(f"MAME: {len(mame)} samples, writes {sum(1 for _ in open(wr))}, sound from sample {nz[0] if len(nz) else '-'}")
    rc = 1
    for ph in a.phase:
        out = d / f"rtl_phase{ph}.txt"
        args = [shutil.which("bash") or "bash", "scripts/run_verilator.sh", "k539_tb",
                f"+smp={(d / 'smp.hex').as_posix()}", f"+writes={wr.as_posix()}",
                f"+out={out.as_posix()}", f"+phase={ph}", f"+n={len(mame)}"]
        r = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
        late = sum(1 for ln in r.stdout.splitlines() if ln.startswith("late write"))
        if not out.exists():
            sys.exit(r.stdout[-3000:] + r.stderr[-3000:])
        rtl = np.loadtxt(out, dtype=np.int64).reshape(-1, 2)
        print(f"phase {ph}: {len(rtl)} samples, {late} late writes")
        for lag in range(-544, -538):          # RTL sample n against MAME's n + lag (the WAV starts late)
            lo, hi = max(0, -lag), min(len(rtl), len(mame) - lag)
            x, y = rtl[lo:hi], mame[lo + lag:hi + lag]
            snd = np.any(y != 0, axis=1) | np.any(x != 0, axis=1)
            if not snd.any():
                continue
            dd = np.abs(x[snd] - y[snd])
            exact = np.mean(np.all(dd == 0, axis=1)) * 100
            near = np.mean(np.all(dd <= 1, axis=1)) * 100
            print(f"  lag {lag:+d}: {snd.sum()} samples with sound, exact {exact:6.2f}%, within 1 {near:6.2f}%, max |d| {dd.max()}")
            if near > 99.9:
                rc = 0
    return rc


if __name__ == "__main__":
    sys.exit(main())
