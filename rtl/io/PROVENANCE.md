# Light guns provenance

`gx_guns.sv` from <https://github.com/ppriest/Arcade-KonamiGX_MiSTer> at commit `89124d4`, path
`rtl/gx_guns.sv`. **Verbatim.** SPDX `GPL-3.0-or-later`. `.gitattributes` marks this directory
`-text`.

It implements Lethal Enforcers II's guns from `konamigx.cpp`: aim from stick, d-pad and mouse,
Reload as an off-screen shot, and the crosshair. Lethal Enforcers' scaling differs (`lethal.cpp`
lines 452-529):

- X = v x 287/255 + 16, read as X>>1, with the low bit at 0x40db.
- Y = v x 223/255 + 10; reads 0 outside 0x0b-0xe8, else 232 - Y.

`lethal_guns.sv` carries that change; `gx_guns.sv` stays as upstream for reference. No upstream test.

`gx_keyboard.sv` from the same repository at commit `9e3f95e`, `rtl/gx_keyboard.sv`, verbatim:
MAME's default keys in hps_io's joystick layout.

`lethal_guns.sv` is this core's fork of `gx_guns.sv` with Lethal Enforcers' scaling; its header
says what changed.
