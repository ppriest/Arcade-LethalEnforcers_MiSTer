#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""When a set's hiscore.dat table settles in MAME, from power-on with a fresh NVRAM.

    python scripts/hs_ready.py lethalen [--frames 1800]

Prints each frame on which the ranges change and the last one: hiscore.v must not start
its checks before the game has finished writing its own table (build_mra.py's
HS_READY_FRAME, after KonamiGX's).
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
from build_mra import hiscore_entries, hiscore_dat  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", type=int, default=1800)
    a = ap.parse_args()
    ents = hiscore_entries(a.set, hiscore_dat(), check_ready=False)
    if not ents:
        sys.exit(f"{a.set}: no hiscore.dat entry this core can hold")
    mame_dir, exe = mame_paths()
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_runner_env("hs_watch.lua"), CORE_FRAMES=str(a.frames),
                   HS_RANGES=" ".join(f"{ad:x}:{n:x}" for ad, n, _, _ in ents))
        cmd = mame_cmd(exe, a.set, "hs_watch.lua", mame_dir, ["-nvram_directory", nv])
        r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True,
                           timeout=1800, **NO_WINDOW)
    if "CORE_CAPTURE_OK" not in r.stdout:
        sys.exit(f"MAME run failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    lines = [ln.split() for ln in r.stdout.splitlines() if ln.startswith("HS ")]
    for _, fr, h in lines:
        print(f"frame {fr:>5}  {h[:32]}{'...' if len(h) > 32 else ''}  start {h[:2]} end {h[-2:]}")
    print(f"{a.set}: last change at frame {lines[-1][1]} of {a.frames}; entries {[(hex(x), n, hex(s), hex(e)) for x, n, s, e in ents]}")


if __name__ == "__main__":
    main()
