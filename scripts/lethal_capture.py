#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture Lethal Enforcers' video state from MAME (scripts/mame/lethal_video.lua).

    python scripts/lethal_capture.py <set> --frame 1200 [--name title] [--coin 600]
    -> debug/<set>-<name>/   (name defaults to f<frame>, with a _play suffix under --coin)

The input to scripts/render_model.py: VRAM and registers read from MAME's
K056832, sprite RAM as the 053244 DMA copied it, palette, palette banks,
and MAME's screenshot of the same frame.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def capture(game, frame, name, coin=0):
    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{game}-{name}"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    env = dict(os.environ, **lua_runner_env("lethal_video.lua"), CORE_OUT=out.as_posix(),
               CORE_FRAME=str(frame), LC_COIN=str(coin))
    nv = out / "nvram"
    cmd = mame_cmd(exe, game, "lethal_video.lua", mame_dir, ["-nvram_directory", nv.as_posix()])
    r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True,
                       timeout=3600, **NO_WINDOW)
    check_lua_error(out)
    if "CORE_CAPTURE_OK" not in r.stdout:
        sys.exit(f"capture failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    shutil.rmtree(nv, ignore_errors=True)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frame", type=int, required=True)
    ap.add_argument("--name")
    ap.add_argument("--coin", type=int, default=0, help="frame of the first of two coins")
    a = ap.parse_args()
    name = a.name or (f"f{a.frame}" + ("_play" if a.coin else ""))
    out = capture(a.set, a.frame, name, a.coin)
    print(out)
    print((out / "manifest.txt").read_text())


if __name__ == "__main__":
    main()
