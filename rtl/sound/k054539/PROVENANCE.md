# K054539 provenance

`gx_k054539.sv` from <https://github.com/ppriest/Arcade-KonamiGX_MiSTer> at commit `89124d4`, path
`rtl/sound/gx_k054539.sv`. **Verbatim.** SPDX `GPL-3.0-or-later`; written in that project from
MAME's `sound/k054539.cpp`. `.gitattributes` marks this directory `-text`.

jtcores' own `modules/jt539` is a submodule pinned at `a8cc904`, whose repository `jotego/jt539`
returns 404 to this account, so the jtcores-first rule cannot reach it. jtcores' Xexex core, in the
local fork, uses this same file.

It expects a 48 MHz clock and a 48 kHz sample strobe (`smp`), which this core's clock plan gives
exactly. KonamiGX has no unit bench for it; it was checked there on hardware, by ear.
