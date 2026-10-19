#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""mc6809i against MAME's boot trace, end to end. Phase 0.

    python scripts/boot_bench.py <set> <accesses> [--irq] [--romlat N] [--mame N]

1. the set's program ROM -> debug/roms/<set>.hex (outside debug/<set>-boot/, which
   mame_boot_trace.py recreates on every capture)
2. MAME's trace, --mame accesses (default: 1.1 x <accesses>), unless one of at
   least that length is already there
3. the I/O replay, the bench (sim/boot_tb, Verilator), and compare_boot_trace.py
"""
import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import rompath, mame_paths  # noqa: E402

PROGRAM = {"lethalen": "191uae01.u4", "lethalenub": "191uab01.u4", "lethalenua": "191uaa01.u4",
           "lethalenux": "191xxx01.u4", "lethaleneae": "191eae01.u4", "lethalenead": "191ead01.u4",
           "lethaleneab": "191eab01.u4", "lethaleneaa": "191_a01.u4", "lethalenj": "191jad01.u4"}


def program_rom(game):
    mame_dir, _ = mame_paths()
    want = PROGRAM[game]
    for d in rompath(mame_dir).split(";"):
        z = Path(d) / "lethalen.zip"
        if z.exists():
            with zipfile.ZipFile(z) as f:
                for n in (want, f"{game}/{want}"):
                    if n in f.namelist():
                        return f.read(n)
    sys.exit(f"{want} not found in lethalen.zip on the ROM path")


def trace_len(path):
    if not path.exists():
        return 0
    with open(path, "rb") as f:
        f.seek(max(0, path.stat().st_size - 200))
        tail = f.read().decode(errors="replace")
    for ln in tail.splitlines():
        if ln.startswith("# ") and "logged" in ln:
            return int(ln.split()[1])
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("n", type=int)
    ap.add_argument("--irq", action="store_true")
    ap.add_argument("--romlat", type=int, default=0)
    ap.add_argument("--mame", type=int, default=0)
    a = ap.parse_args()

    hexf = REPO / "debug" / "roms" / f"{a.game}.hex"
    hexf.parent.mkdir(parents=True, exist_ok=True)
    data = program_rom(a.game)
    assert len(data) == 0x40000
    hexf.write_text("\n".join(f"{b:02x}" for b in data) + "\n")

    base = REPO / "debug" / f"{a.game}-boot"
    need = a.mame or int(a.n * 1.1)
    if trace_len(base / f"{a.game}_boot.trace") < need:
        subprocess.run([sys.executable, "scripts/mame_boot_trace.py", a.game, str(need),
                        "--seconds", "300"], cwd=REPO, check=True)
    subprocess.run([sys.executable, "scripts/compare_boot_trace.py", "replay", a.game], cwd=REPO, check=True)
    # Windows' process search tries System32 before PATH, where bash.exe is WSL's launcher
    bash = shutil.which("bash") or "bash"
    r = subprocess.run([bash, "scripts/run_verilator.sh", "boot_tb", f"+rom={hexf.as_posix()}",
                        f"+replay={(base / f'{a.game}_replay.txt').as_posix()}",
                        f"+out={(base / f'{a.game}_rtl.trace').as_posix()}", f"+n={a.n}",
                        f"+romlat={a.romlat}", f"+irq={1 if a.irq else 0}"],
                       cwd=REPO, capture_output=True, text=True)
    lines = (r.stdout + r.stderr).splitlines()
    for ln in lines:
        if ln.startswith(("TRACE", "CYCLES", "GAME", "cannot open", "%Error")):
            print(ln)
    mism = [ln for ln in lines if ln.startswith(("I/O read", "replay exhausted"))]
    if mism:
        print(f"{len(mism)} replay warnings; first: {mism[0]}")
    return subprocess.run([sys.executable, "scripts/compare_boot_trace.py", "compare", a.game],
                          cwd=REPO).returncode


if __name__ == "__main__":
    sys.exit(main())
