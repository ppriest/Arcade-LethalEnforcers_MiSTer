#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerate every vendored *_mmr.v with jotego's generator (tools/jtframe).
#
#     JTCORES=<jtcores checkout> scripts/regen_mmr.sh            # rewrite in place
#     JTCORES=<jtcores checkout> scripts/regen_mmr.sh --check    # diff only
#
# The checkout supplies cfg/mmr.yaml and the generator's template
# ($JTFRAME/hdl/inc/mmr.v); it must be at the commit tools/jtframe/PROVENANCE.md
# names. Run --check after any change to that snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

TOOL="$PWD/tools/jtframe/jtframe.exe"
[ -x "$TOOL" ] || { echo "build it first: tools/jtframe/build.sh"; exit 1; }
: "${JTCORES:?set JTCORES to a jtcores checkout}"
[ -d "$JTCORES/cores" ] || { echo "JTCORES=$JTCORES has no cores/"; exit 1; }

export JTFRAME="$JTCORES/modules/jtframe"
export JTROOT="$JTCORES" CORES="$JTCORES/cores" MODULES="$JTCORES/modules"
export JTBIN="${JTBIN:-$PWD/debug/jtbin}"
mkdir -p "$JTBIN"

declare -A WANT=(
  ["$JTCORES/cores/simson/hdl/jt053246_mmr.v"]="rtl/video/jt053244/jt053246_mmr.v"
  ["$JTCORES/cores/simson/hdl/jtk054000_mmr.v"]="rtl/misc/jtk054000/jtk054000_mmr.v"
)

( cd "$JTCORES" && "$TOOL" mmr simson )

rc=0
for src in "${!WANT[@]}"; do
  dst="${WANT[$src]}"
  [ -f "$src" ] || { echo "MISSING generated file: $src"; rc=1; continue; }
  if [ "$CHECK" = 1 ]; then
    if cmp -s "$src" "$dst"; then echo "  same     $dst"; else echo "  DRIFTED  $dst"; rc=1; fi
  else
    cp "$src" "$dst"; echo "  wrote    $dst"
  fi
done
exit $rc
