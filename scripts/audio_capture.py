#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's audio for a set, from power-on with a fresh NVRAM, with coins and Start.

    python scripts/audio_capture.py lethalen [--coin 400] [--frames 1200]
    -> debug/audio/<set>_mame.wav (48 kHz stereo, -wavwrite)

scripts/mame/audio_play.lua presses the inputs; sim/system_tb's +coin= does the same
for the RTL (scripts/check_system.py --audio --coin), and scripts/compare_audio.py
compares the two.
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--coin", type=int, default=400)
    ap.add_argument("--frames", type=int, default=1200)
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    out = REPO / "debug" / "audio"
    out.mkdir(parents=True, exist_ok=True)
    wav = out / f"{a.set}_mame.wav"
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_runner_env("audio_play.lua"), CORE_FRAMES=str(a.frames), LC_COIN=str(a.coin))
        cmd = mame_cmd(exe, a.set, "audio_play.lua", mame_dir,
                       ["-nvram_directory", nv, "-wavwrite", str(wav), "-samplerate", "48000"])
        r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True, timeout=3600, **NO_WINDOW)
    if "CORE_CAPTURE_OK" not in r.stdout:
        sys.exit(f"MAME run failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    print(wav)


if __name__ == "__main__":
    main()
