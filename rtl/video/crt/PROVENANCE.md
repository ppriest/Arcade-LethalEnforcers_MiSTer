# rtl/video/crt provenance

From <https://github.com/ppriest/Arcade-KonamiGX_MiSTer> at commit `9e3f95e`, verbatim,
GPL-3.0-or-later:

- `crt_adjust.sv`: Umberto Parisi (rmonic79), via Arcade-Psikyo_MiSTer `8e39bb6`, with GX's
  `LOCAL FIX` (signed H-Position offset). GX's `rtl/video/crt/PROVENANCE.md` has the chain.
- `gx_crt_chain.sv`: GX's glue (H-Position, V-Shift, H-Size; no V-Size). Its `VTOTAL` is set to
  262 by the instance in `LethalEnforcers.sv`.
