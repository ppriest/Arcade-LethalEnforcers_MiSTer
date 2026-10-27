# LethalEnforcers state inventory

What a savestate or a state dump has to carry, kept current as RTL lands. "Skip" needs a reason:
a ROM table from the `.mra`, or something re-derived every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| 6809 work RAM | `lethal_main`, `jtframe_sys6809_dma` `u_ram` | 8 x 8192 | 8 KB | yes; second port is `hs_*` |
| EEPROM | `lethal_main` `ee_ram` | 8 x 128 | 128 | yes; second port is `nv_*` (also the `.nvm`) |
| Palette | `lethal_mixer` `pal_hi`/`pal_lo` | 2 x 8 x 8192 | 16 KB | yes; CPU port only |
| VRAM, 5 pages | `lethal_tilemap` `g_vram[0..3]` | 4 x 8 x 16384 | 64 KB (40 KB used) | yes; CPU port only |
| Sprite RAM (053245) | `lethal_obj` `ram_hi`/`ram_lo` | 2 x 8 x 1024 | 2 KB | yes; CPU port only |
| Sprite DMA copy | `jt053244` `u_even`/`u_odd` | 4 x 16 x 1024 | 8 KB | yes: re-copied only at the next DMA |
| Z80 RAM | `lethal_sound` `ram` | 8 x 2048 | 2 KB | yes |
| 054539 RAM | `lethal_k539` `kram_lo`/`kram_hi` | 2 x 8 x 16384 | 32 KB | yes |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| 6809 registers | `mc6809i` | - | yes; not reachable yet | the CPU's own |
| ROM bank, CBNK, control2, IRQ enable and hold | `lethal_main` `rbank`, `cbnk`, `control2`, `irq_en`, `irq_hold` | 5+1+8+1+1 | yes | `m_cur_control2`, the bank |
| PCU registers | `lethal_main` `pcu1..3` | 24 | yes | `m_layer_colorbase` etc. |
| 054156 registers | `lethal_tilemap` `regs` | 32 x 16 | yes | `k056832` |
| 053244 registers | `jt053244` MMR | - | yes | `k053244` |
| Z80 registers | T80 | - | yes; not reachable yet | the CPU's own |
| 054321 volume and enables | `lethal_k539` `k321_vol`, `k321_active` | 7+8 | yes | `m_volume`, `m_active` |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| 054539 | `gx_k054539` | registers through its `ss_*` port | - | voice state is internal |
| 054321 | `jt054321` | no | - | latches and volume |
| 054000 | `jtk054000` | MMR | - | |
| ER5911 | `jt5911` | data yes (`nv_*`), FSM no | - | |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| Z80 program | ROM, loaded from the `.mra` |
| Tile and sprite line buffers | refilled every line |
| Main program cache (`lethal_sdram`) | refilled from SDRAM |

## Frame alignment

Restore point (normally `frame_start`), and anything whose phase must be saved with it: sprite or
tile double-buffer selection, snapshot ownership bits.
