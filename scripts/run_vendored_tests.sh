#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the upstream tests of the vendored modules against rtl/, as the
# regression WORKFLOW section 12 requires. Icarus Verilog from MSYS2.
#
#     JTCORES=<jtcores at f64dbe2fd> scripts/run_vendored_tests.sh
#
# JTCORES supplies only Micron's SDRAM model (modules/jtframe/hdl/ver/
# mt48lc16m16a2.v), which carries no redistribution grant and is not committed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export PATH="/e/msys64/mingw64/bin:$PATH"
: "${JTCORES:?set JTCORES to a jtcores checkout (for the Micron SDRAM model)}"
MT48="$JTCORES/modules/jtframe/hdl/ver/mt48lc16m16a2.v"
[ -f "$MT48" ] || { echo "missing $MT48"; exit 1; }

OUT="$ROOT/debug/vendored_tests"
rm -rf "$OUT"; mkdir -p "$OUT"
V="$ROOT/sim/jtframe_ver"
rc=0

# Icarus here stops reading options at the first file name: options go first.
sdram() {   # name, extra iverilog options
    local name=$1; shift
    local d="$OUT/$name"; mkdir -p "$d"; cd "$d"
    for b in 0 1 2 3; do dd if=/dev/urandom of=sdram_bank$b.bin bs=1M count=8 2>/dev/null; done
    iverilog -o t.vvp -DJTFRAME_SDRAM_BANKS -DSIMULATION -DSDRAM_SHIFT=0 "$@" \
        "$V/sdram_bank64_rw/test.v" "$ROOT"/rtl/jtframe/sdram/jtframe_sdram64*.v "$MT48"
    vvp -n t.vvp -lxt > t.log 2>&1 || true
    if grep -q PASSED t.log && ! grep -q FAIL t.log; then echo "PASS $name"; else echo "FAIL $name ($d/t.log)"; rc=1; fi
    cd "$ROOT"
}
draw() {    # test directory name
    local name=$1 d="$OUT/$1"; mkdir -p "$d"; cd "$d"
    iverilog -g2012 -I"$V/inc" -o t.vvp -DSIMULATION "$V/$name/test.v" "$ROOT/rtl/jtframe/jtframe_draw.v"
    vvp -n t.vvp > t.log 2>&1 || true
    if grep -q "^PASS" t.log && ! grep -q FAIL t.log; then echo "PASS $name"; else echo "FAIL $name ($d/t.log)"; rc=1; fi
    cd "$ROOT"
}

# upstream short.sh: 25 ms, bank 0 32-word and bank 1 16-word bursts
sdram sdram_bank64_short -DSIM_TIME=25_000_000 -Ptest.BA0_LEN=32 -Ptest.BA1_LEN=16
# the same at this core's 48 MHz, with MiSTer's DQM constraint
sdram sdram_bank64_mister48 -DSIM_TIME=25_000_000 -Ptest.BA0_LEN=32 -Ptest.BA1_LEN=16 \
    -DMISTER -DJTFRAME_SDRAM_ADQM -DPERIOD=20.833
draw draw_scaling_single
draw draw_scaling_multi
exit $rc
