#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Which K056832 VRAM pages each set writes, from MAME (scripts/mame/vram_pages.lua).

    python scripts/mame_vram_pages.py <set> [<set> ...] [--frames 3600] [--coin 1200]
    -> debug/vram_pages/<set><tag>_vram_pages.txt

Sizes the tilemap VRAM: the board's populated RAM against MAME's 16 pages + 1.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--frames", type=int, default=3600)
    ap.add_argument("--coin", type=int, default=0, help="frame of the first of two coins; 0 = attract")
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    for game in a.sets:
        out = REPO / "debug" / "vram_pages"
        out.mkdir(parents=True, exist_ok=True)
        tag = f"{game}{a.tag}"
        env = dict(os.environ, **lua_runner_env("vram_pages.lua"), CORE_OUT=out.as_posix(),
                   CORE_TAG=tag, VP_FRAMES=str(a.frames), VP_COIN=str(a.coin))
        cmd = mame_cmd(exe, game, "vram_pages.lua", mame_dir,
                       ["-snapshot_directory", (out / "snap").as_posix(), "-snapview", "native"])
        subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
        check_lua_error(out)
        res = out / f"{tag}_vram_pages.txt"
        print(f"== {tag}")
        print(res.read_text() if res.exists() else "  no result")


if __name__ == "__main__":
    main()
