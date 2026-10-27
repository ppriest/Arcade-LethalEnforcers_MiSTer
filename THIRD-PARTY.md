# Third-party code and licences

**This project is GPL-3.0-or-later.** `LICENSE` carries the GPLv3 text. jtcores and the KonamiGX
modules it reuses are GPL-3.0-or-later, so the combined work is too. Code can come in from
GPL-2-or-later MiSTer cores; code written here cannot go back to them unless its author also offers
it under GPL-2-or-later.

Each vendored directory's `PROVENANCE.md` names the upstream commit and records every local change.
This file records what each dependency obliges.

| Component | Where | Licence | Obligation |
|---|---|---|---|
| MiSTer `sys/` framework | `sys/` | GPL-2.0-or-later | never edited; combined under GPL-3 |
| jtcores HDL (jtframe RAM, SDRAM, draw; jt053244; jtk054000; jt054321; `jtframe_sys6809`; `jtframe_z80`) | `rtl/jtframe`, `rtl/video`, `rtl/misc/jtk054000`, `rtl/sound/jt054321`, `rtl/cpu` | GPL-3.0-or-later | source with the binary; §5(a) notice on any modified file |
| jteeprom `jt5911` | `rtl/misc/jt5911` | GPL-3.0-or-later | as above |
| jtframe tool (Go) | `tools/jtframe/src` | GPL-3.0-or-later | as above |
| KonamiGX `gx_k054539`, `gx_guns`; `lethal_tilemap.sv` derived from its `gx_tilemap.sv` | `rtl/sound/k054539`, `rtl/io`, `rtl/video` | GPL-3.0-or-later | as above |
| KonamiGX `gx_rom_loader`, `ddram_phy`, `gx_keyboard`, `gx_crt_chain`, `hiscore.v`, `issp_probe`, the 054539 model `k054539_model.py` | `rtl/memory`, `rtl/io`, `rtl/video/crt`, `rtl/hiscore`, `rtl/debug`, `scripts/k054539_model.py` | GPL-3.0-or-later (`crt_adjust.sv`: rmonic79; `hiscore.v`: Steremberg, Gregory) | as above |
| `screen_rotate_two` (Sorgelig, via KonamiGX) | `rtl/video/rotate` | GPL-2.0-or-later | combined under GPL-3 |
| mc6809i (Greg Miller) | `rtl/cpu/mc6809/mc6809i.v` | BSD, below | keep the notice in source; reproduce it in binary documentation |
| T80 (Daniel Wallner, Sorgelig) | `rtl/cpu/t80/T80*` | BSD-style, in each header | keep the notice in source; reproduce it in binary documentation |

## mc6809i

Upstream (<https://github.com/cavnex/mc6809>, `documentation/LICENSE.md`) offers two licences and
asks that one be selected. This project selects the standard BSD licence:

```
Copyright (c) 2016, Greg Miller
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * The name of the author may not be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL GREG MILLER BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## T80

The notice is in the header of each `rtl/cpu/t80/T80*.vhd` file: Copyright (c) 2001-2002 Daniel
Wallner, Copyright (c) 2018 Sorgelig, redistribution in source and synthesised forms permitted with
the notice retained.

## MiSTer-devel/Template_MiSTer - GPL-2.0-or-later (`sys/`)

The framework, unmodified, pinned at `5dda373` (57 files, byte-identical to upstream). Its grant is
"or later", which is what lets it combine with GPL-3 code.

## Release checklist

- The README credits each component above.
- The BSD notices above ship with every release that contains mc6809i or T80.
- No vendored file has been modified without a §5(a) notice; `git log -p` on its directory shows
  every change.
