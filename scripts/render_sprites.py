# SPDX-License-Identifier: GPL-3.0-or-later
"""K053244/K053245 sprites for scripts/render_model.py, as MAME draws them.

k053244_device::sprites_draw (k053244_k053245.cpp) with lethal.cpp's sprite_callback,
its 6 bpp layout (spritelayout_6bpp: two planes from the second half of the region),
MAME's zoomed blit (drawgfxzoom_core) and PIXEL_OP_REBASE_TRANSTABLE16_PRIORITY with
the implicit bit 31 in the mask, so the FIRST sprite drawn at a pixel wins. Sprites are
drawn from priority code 127 down to 0.

The buffer is the 053244's DMA copy (capture objbuf.bin, k053245_r byte order: high
byte first).
"""
import numpy as np

from render_model import BMP_W, BMP_H, VIS_X0, VIS_X1, VIS_Y0, VIS_Y1, load32_word, rom_zip

DRAWMODE_NONE, DRAWMODE_SOURCE, DRAWMODE_SHADOW, DRAWMODE_SHADOW_PRI = 0, 1, 2, 3
SHADOW_OFFSET = 0x2000          # lethal.cpp video_start: shadow pen = pen + entries / 2

_SPR = None


def sprite_gfx():
    """16x16 6 bpp sprites: uint8[16384, 16, 16].

    Region 0x400000: 191a05 at 0, 191a04 at 2, 191a06 at 0x200000 (ROM_LOAD32_WORD),
    the rest zero (ROMREGION_ERASE00). RGN_FRAC(1,2) = 0x200000 bytes. Planes, MSB first:
    { F+8, F+0, 24, 16, 8, 0 } bits with F the half; x offsets 0..7 then 256..263; y
    offsets 32 bits a row, rows 8..15 at 512 bits; 128 bytes a sprite."""
    global _SPR
    if _SPR is None:
        z = rom_zip()
        reg = load32_word(z, [("191a05", 0), ("191a04", 2), ("191a06", 0x200000)], 0x400000)
        n = 0x200000 // 128
        bits = np.unpackbits(reg).reshape(-1)          # MSB first, as MAME's readbit
        half = 0x200000 * 8
        planes = [half + 8, half + 0, 24, 16, 8, 0]
        xo = np.array(list(range(8)) + [256 + i for i in range(8)])
        yo = np.array([32 * i for i in range(8)] + [512 + 32 * i for i in range(8)])
        base = (np.arange(n) * 1024)[:, None, None] + yo[None, :, None] + xo[None, None, :]
        pix = np.zeros((n, 16, 16), dtype=np.uint8)
        for i, p in enumerate(planes):
            pix |= (bits[base + p] << (5 - i)).astype(np.uint8)
        _SPR = pix
    return _SPR


def buffer_words(cap):
    b = np.frombuffer(cap.objbuf, dtype=">u2").astype(int)
    return b


def lethal_callback(code, color, sprite_base):
    """lethal.cpp sprite_callback: (code, color, priority mask)."""
    pri = {0x00: 0x00, 0x10: 0xf0, 0x20: 0xfc, 0x30: 0xfe}[color & 0x30]
    return code & 0x3fff, (color & 0x0f) + sprite_base, pri


def blit(pens, prio, gfx, code, color, flipx, flipy, destx, desty, scalex, scaley, clip, pmask, table):
    """drawgfxzoom_core with PIXEL_OP_REBASE_TRANSTABLE16_PRIORITY, granularity 64,
    256 colours (palette entries / depth)."""
    cx0, cx1, cy0, cy1 = clip
    if cx0 > cx1 or cy0 > cy1:
        return
    dstw = (scalex * 16 + 0x8000) >> 16
    dsth = (scaley * 16 + 0x8000) >> 16
    if dstw < 1 or dsth < 1:
        return
    dx = (16 << 16) // dstw
    dy = (16 << 16) // dsth
    endx = destx + dstw - 1
    if destx > cx1 or endx < cx0:
        return
    srcx = 0
    if destx < cx0:
        srcx = (cx0 - destx) * dx
        destx = cx0
    endx = min(endx, cx1)
    endy = desty + dsth - 1
    if desty > cy1 or endy < cy0:
        return
    srcy = 0
    if desty < cy0:
        srcy = (cy0 - desty) * dy
        desty = cy0
    endy = min(endy, cy1)
    if flipx:
        srcx = (dstw - 1) * dx - srcx
        dx = -dx
    if flipy:
        srcy = (dsth - 1) * dy - srcy
        dy = -dy
    src = gfx[code % len(gfx)]
    cbase = 64 * (color % 256)
    pmask |= 1 << 31
    for y in range(desty, endy + 1):
        row = src[srcy >> 16]
        srcy += dy
        sx = srcx
        for x in range(destx, endx + 1):
            s = int(row[sx >> 16])
            sx += dx
            entry = table[s]
            if entry == DRAWMODE_NONE:
                continue
            pri = int(prio[y, x])
            if entry == DRAWMODE_SOURCE:
                if ((1 << (pri & 0x1f)) & pmask) == 0:
                    if (pri & 0xc0) == (DRAWMODE_SHADOW_PRI << 6):
                        pens[y, x] = (cbase + s) | SHADOW_OFFSET
                    else:
                        pens[y, x] = cbase + s
                prio[y, x] = 31
            elif (pri & 0x80) == 0 and ((1 << (pri & 0x1f)) & pmask) == 0:
                pens[y, x] = pens[y, x] | SHADOW_OFFSET
                prio[y, x] = pri | (entry << 6)


def draw_sprites(cap, pens, prio, sprite_base, z_rejection=0):
    gfx = sprite_gfx()
    buf = buffer_words(cap)
    regs = cap.objregs
    flipscreenx = regs[5] & 1
    flipscreeny = regs[5] & 2
    offsx = (regs[0] << 8) | regs[1]
    offsy = (regs[2] << 8) | regs[3]
    # lethal.cpp screen_update: set_offsets(0, flip Y ? 1 : -1) from 054156 register 0
    m_dx, m_dy = 0, (1 if (cap.regs[0] & 0x20) else -1)

    sortedlist = [-1] * 128
    for offs in range(0, 0x400, 8):
        pc = buf[offs]
        if pc & 0x8000:
            pc &= 0x7f
            if offs and pc == z_rejection:
                continue
            if sortedlist[pc] == -1:
                sortedlist[pc] = offs

    cliprect = (VIS_X0, VIS_X1, VIS_Y0, VIS_Y1)
    drawn = 0
    for pc in range(127, -1, -1):
        offs = sortedlist[pc]
        if offs == -1:
            continue
        code = buf[offs + 1]
        code = ((code & 0xffe1) + ((code & 0x0010) >> 2) + ((code & 0x0008) << 1)
                + ((code & 0x0004) >> 1) + ((code & 0x0002) << 2))
        color = buf[offs + 6] & 0xff
        code, color, pri = lethal_callback(code, color, sprite_base)
        size = (buf[offs] & 0x0f00) >> 8
        w = 1 << (size & 3)
        h = 1 << ((size >> 2) & 3)
        zoomy = buf[offs + 4]
        if zoomy > 0x2000:
            continue
        zoomy = (0x400000 + zoomy // 2) // zoomy if zoomy else 2 * 0x400000
        if (buf[offs] & 0x4000) == 0:
            zoomx = buf[offs + 5]
            if zoomx > 0x2000:
                continue
            zoomx = (0x400000 + zoomx // 2) // zoomx if zoomx else 2 * 0x400000
        else:
            zoomx = zoomy
        ox = buf[offs + 3] + offsx
        oy = buf[offs + 2]
        ox -= 96
        ox += m_dx
        oy += m_dy
        flipx = bool(buf[offs] & 0x1000)
        flipy = bool(buf[offs] & 0x2000)
        mirrorx = bool(buf[offs + 6] & 0x0100)
        if mirrorx:
            flipx = False
        mirrory = bool(buf[offs + 6] & 0x0200)
        shadow = bool(buf[offs + 6] & 0x0080)
        if flipscreenx:
            ox = 320 - ox
            if not mirrorx:
                flipx = not flipx
        if flipscreeny:
            oy = -oy
            if not mirrory:
                flipy = not flipy
        ox = (ox + 0x5d) & 0x3ff
        if ox >= 768:
            ox -= 1024
        oy = (-(oy + offsy + 0x07)) & 0x3ff
        if oy >= 640:
            oy -= 1024
        clip = (max(ox - 0x200, cliprect[0]), min(ox + 0x1ff, cliprect[1]),
                max(oy - 0x100, cliprect[2]), min(oy + 0xff, cliprect[3]))
        ox -= (zoomx * w) >> 13
        oy -= (zoomy * h) >> 13
        table = [DRAWMODE_SOURCE] * 64
        table[0] = DRAWMODE_NONE
        table[63] = DRAWMODE_SHADOW_PRI if shadow else DRAWMODE_SOURCE
        for y in range(h):
            sy = oy + ((zoomy * y + (1 << 11)) >> 12)
            zh = (oy + ((zoomy * (y + 1) + (1 << 11)) >> 12)) - sy
            for x in range(w):
                sx = ox + ((zoomx * x + (1 << 11)) >> 12)
                zw = (ox + ((zoomx * (x + 1) + (1 << 11)) >> 12)) - sx
                c = code
                if mirrorx:
                    if (not flipx) ^ (2 * x < w):
                        c += w - x - 1
                        fx = True
                    else:
                        c += x
                        fx = False
                else:
                    c += (w - 1 - x) if flipx else x
                    fx = flipx
                if mirrory:
                    if (not flipy) ^ (2 * y >= h):
                        c += 8 * (h - y - 1)
                        fy = True
                    else:
                        c += 8 * y
                        fy = False
                else:
                    c += 8 * (h - 1 - y) if flipy else 8 * y
                    fy = flipy
                c = (c & 0x3f) | (code & ~0x3f)
                if zoomx == 0x10000 and zoomy == 0x10000:
                    blit(pens, prio, gfx, c, color, fx, fy, sx, sy, 1 << 16, 1 << 16, clip, pri, table)
                else:
                    blit(pens, prio, gfx, c, color, fx, fy, sx, sy, zw << 12, zh << 12, clip, pri, table)
        drawn += 1
    return drawn
