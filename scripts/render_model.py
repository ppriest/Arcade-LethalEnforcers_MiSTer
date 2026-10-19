#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A software model of Lethal Enforcers' video, checked against MAME captures.

    python scripts/render_model.py lethalen-f1200            # model vs reference.png
    python scripts/render_model.py lethalen-f1200 --stage tiles

Reads a capture from scripts/lethal_capture.py (debug/<set>-<name>/) and renders it
the way lethal.cpp's screen_update does, with MAME's K056832 and K053244 models,
then compares with MAME's screenshot of the same frame. Phase 1 of docs/ROADMAP.md:
this model is made pixel-exact against MAME first; the RTL is checked against it.

COORDINATES are MAME's bitmap's: 384 x 262 total, visible x 24..311, y 16..239
(lethal.cpp line 695). Screen flip is the game's (054156 register 0 bits 4-5),
applied the way MAME's tilemap and sprite code apply it; MAME's orientation
(ORIENTATION_FLIP_Y, or FLIP_X for lethalenj) is then applied to the visible
window, as MAME does to the screenshot.

STAGES
  tiles   background fill and the four K056832 layers, no sprites
  full    tiles plus the K053244 sprites and lethal.cpp's mixing
"""
import argparse
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

VIS_X0, VIS_X1, VIS_Y0, VIS_Y1 = 24, 311, 16, 239
BMP_W, BMP_H = 384, 262
ORIENT = {"lethalenj": "flipx"}          # every other set: flipy (lethal.cpp lines 957-968

# ---------------------------------------------------------------- ROMs


def rom_zip():
    from mame_capture import mame_paths, rompath
    mame_dir, _ = mame_paths()
    for d in rompath(mame_dir).split(";"):
        z = Path(d) / "lethalen.zip"
        if z.exists():
            return zipfile.ZipFile(z)
    sys.exit("lethalen.zip not found on the ROM path")


def load32_word(z, parts, size):
    """ROM_LOAD32_WORD: each file's 16-bit words go to every fourth byte pair."""
    r = np.zeros(size, dtype=np.uint8)
    for name, offs in parts:
        d = np.frombuffer(z.read(name), dtype=np.uint8)
        w = d.reshape(-1, 2)
        idx = offs + np.arange(len(w)) * 4
        r[idx] = w[:, 0]
        r[idx + 1] = w[:, 1]
    return r


_TILES = None


def tile_gfx():
    """K056832 8LE tiles (charlayout8le), decoded: uint8[65536, 8, 8].

    Planes { H+0..H+3, 0..3 } with H = 0x200000 bytes: the second half of the region gives
    the high nibble. x offsets { 8, 12, 0, 4, 24, 28, 16, 20 } bits; 32 bits a row; 32 bytes
    a tile. Bits are numbered MSB first, as MAME's gfx decoder reads them. total =
    region / (8 * 8) = 65536: create_gfx divides by 8 when `big` is set, and lethal.cpp
    line 705 sets it (set_config(K056832_BPP_8LE, 1, 0))."""
    global _TILES
    if _TILES is None:
        z = rom_zip()
        reg = load32_word(z, [("191a08", 2), ("191a10", 0), ("191a07", 0x200002), ("191a09", 0x200000)],
                          0x400000)
        lo = reg[:0x200000].reshape(-1, 8, 4)     # tile, row, byte
        hi = reg[0x200000:].reshape(-1, 8, 4)
        def nib(a):
            # pixel x -> (byte, high nibble?) from the x offsets
            sel = [(1, 1), (1, 0), (0, 1), (0, 0), (3, 1), (3, 0), (2, 1), (2, 0)]
            return np.stack([(a[:, :, b] >> 4) if h else (a[:, :, b] & 15) for b, h in sel], axis=2)
        _TILES = ((nib(hi) << 4) | nib(lo)).astype(np.uint8)
    return _TILES


# ---------------------------------------------------------------- capture


class Capture:
    def __init__(self, name):
        self.dir = REPO / "debug" / name
        if not self.dir.exists():
            sys.exit(f"no capture {self.dir}")
        m = dict(ln.split(" ", 1) for ln in (self.dir / "manifest.txt").read_text().splitlines() if " " in ln)
        self.set = m["set"].strip()
        self.vram = np.frombuffer((self.dir / "k056832_vram.bin").read_bytes(), dtype="<u2")
        self.regs = np.frombuffer((self.dir / "k056832_regs.bin").read_bytes(), dtype="<u2").astype(int)
        self.items = {}
        for ln in (self.dir / "k056832_items.txt").read_text().splitlines():
            name, size, count, hexs = ln.split()
            size, count = int(size), int(count)
            b = bytes.fromhex(hexs)
            dt = {1: "<i1", 2: "<i2", 4: "<i4", 8: "<i8"}[size]
            self.items[name] = np.frombuffer(b, dtype=dt).astype(np.int64)
        self.objbuf = (self.dir / "objbuf.bin").read_bytes()
        self.objregs = (self.dir / "k053244_regs.bin").read_bytes()
        self.palraw = (self.dir / "palette.bin").read_bytes()
        self.ctrl = (self.dir / "ctrl.bin").read_bytes()
        self.ref = np.asarray(Image.open(self.dir / "reference.png").convert("RGB"))

    def item(self, name):
        return self.items[name]


# ---------------------------------------------------------------- palette


def pal5(v):
    return (v << 3) | (v >> 2)


def palette_rgb(cap, endian=">"):
    """0x2000 xBGR_555 entries, then the shadow table: the same with red x 0.6
    (lethal.cpp palette_w, PALETTE_DEFAULT_SHADOW_FACTOR)."""
    w = np.frombuffer(cap.palraw, dtype=endian + "u2").astype(int)
    r, g, b = pal5(w & 31), pal5((w >> 5) & 31), pal5((w >> 10) & 31)
    rgb = np.stack([r, g, b], axis=1)
    shadow = rgb.copy()
    shadow[:, 0] = (shadow[:, 0] * 0.6).astype(int)
    return np.concatenate([rgb, shadow]).astype(np.uint8)


def colorbases(cap):
    """lethal.cpp palette_control_w, from the last values written to PCU1-3."""
    pcu1, pcu2, pcu3 = cap.ctrl[1], cap.ctrl[2], cap.ctrl[3]
    layer = [(pcu1 & 7) * 64, ((pcu1 >> 4) & 7) * 64, (pcu2 & 7) * 64, ((pcu2 >> 4) & 7) * 64]
    sprite = (pcu3 & 7) * 16
    back = ((pcu3 >> 4) & 7) * 1024 + 1023
    return layer, sprite, back


# ---------------------------------------------------------------- K056832

SHIFTMASKS = [(6, 0x3f, 0, 0x00), (4, 0x0f, 2, 0x30), (2, 0x03, 2, 0x3c), (0, 0x00, 2, 0x3f)]


def page_pixels(cap, page, layer, lx, ly, layer_base):
    """Pens (0 = transparent) of logical page pixels (lx 0..511, ly 0..255):
    get_tile_info plus lethal.cpp tile_callback."""
    tiles = tile_gfx()
    idx = (ly >> 3) * 64 + (lx >> 3)
    base = (page << 12) + (idx << 1)
    attr = cap.vram[base].astype(int)
    code = cap.vram[base + 1].astype(int)
    fbits = (cap.regs[3] >> 6) & 3
    flips, palm1, pals2, palm2 = SHIFTMASKS[fbits]
    flip = ((cap.regs[1] >> (layer << 1)) & 3) & ((attr >> flips) & 3)
    color = (attr & palm1) | ((attr >> pals2) & palm2)
    color = layer_base + ((color & 0x3c) << 2)
    px = lx & 7
    py = ly & 7
    px = np.where(flip & 1, 7 - px, px)
    py = np.where(flip & 2, 7 - py, py)
    pix = tiles[code % 65536, py, px].astype(int)
    pen = 16 * (color % 1024) + pix
    return np.where(pix != 0, pen, 0)


def draw_layer(cap, layer, layer_base):
    """One K056832 layer into a full bitmap of pens (0 = transparent), as
    tilemap_draw_common does for xy scroll, rowscroll and linescroll."""
    it = cap.item
    rowstart, colstart = int(it("m_y")[layer]), int(it("m_x")[layer])
    rowspan, colspan = int(it("m_h")[layer]) + 1, int(it("m_w")[layer]) + 1
    dy, dx = int(it("m_dy")[layer]), int(it("m_dx")[layer])
    offs = it("m_layer_offs").reshape(8, 2)
    lsram = it("m_lsram_page").reshape(8, 2)
    assoc = it("m_layer_assoc_with_page")
    assert int(it("m_layer_association")[0]) == 1, "layer association off: not modelled"
    regs = cap.regs
    scrollmode = (regs[5] >> (int(lsram[layer][0]) << 1)) & 3
    height, width = rowspan * 256, colspan * 512

    flipy = regs[0] & 0x20
    corr_y = 0
    if flipy:
        corr_y = regs[0x1e]
        if corr_y & 0x400:
            corr_y -= 0x800
    flipx = regs[0] & 0x10
    corr_x = 0
    if flipx:
        corr_x = regs[0x1d]
        if corr_x & 0x800:
            corr_x -= 0x1000
    corr_x -= int(offs[layer][0])
    dy += corr_y
    ay = (dy - int(offs[layer][1])) % height

    if rowspan != 1 or colspan != 1:
        raise NotImplementedError(f"layer {layer}: {rowspan}x{colspan} pages")
    page = ((rowstart & 3) << 2) + (colstart & 3)
    if assoc[page] != layer:
        return np.zeros((BMP_H, BMP_W), dtype=int)
    if not it("m_page_tile_mode")[page]:
        raise NotImplementedError(f"page {page} in line-map mode")

    # per bitmap line, the x scroll (tilemap_draw_common's line loop)
    ext = int(it("m_use_ext_linescroll")[0])
    scrollbank = 16 if ext else ((regs[0x18] >> 1) & 0xc) | (regs[0x18] & 3)
    ys = np.arange(BMP_H)
    if scrollmode in (0, 2):
        sbase = (scrollbank << 12) + (int(lsram[layer][1]) >> 1)
        line_h = 1 if scrollmode == 0 else 8
        adv = 2 if scrollmode == 0 else 16
        start = 255 if flipy else dy
        if scrollmode == 2:
            start &= ~7
        start <<= 1
        if flipy:
            adv = -adv
        # line_starty -= dy & 7 for rowscroll: bitmap line y uses group (y + (dy & 7)) // 8
        grp = ys // line_h if scrollmode == 0 else (ys + (dy & 7)) // 8
        sofs = (start + grp * adv) & 0x3ff
        if scrollmode == 2 and flipy:
            # lethal.cpp draws with K056832_DRAW_FLAG_MIRROR: rowscroll under flip Y reads
            # p_scroll_data[sdat_offs + 0x1e0 + 14] (tilemap_draw_common)
            sofs = sofs + 0x1e0 + 14
        # lines outside the visible window can index past the end of MAME's VRAM; they are
        # never shown, so clamp them
        sidx = np.minimum(sbase + sofs, len(cap.vram) - 2)
        sdx = ((cap.vram[sidx].astype(int) << 16) | cap.vram[sidx + 1].astype(int))
        sdx = np.where(sdx & 0x80000000, sdx - (1 << 32), sdx) + corr_x
    else:
        sdx = np.full(BMP_H, dx + corr_x)

    # MAME tilemap_t with set_flip (register 0) and scrolldx = scrolldy = 0
    xext = VIS_X1 + VIS_X0 + 1
    yext = VIS_Y1 + VIS_Y0 + 1
    xs = np.arange(BMP_W)
    X, Y = np.meshgrid(xs, ys)
    SDX = sdx[:, None]
    if not flipx:
        lx = (X + SDX) % 512
    else:
        lx = (xext - 1 - X + SDX) % 512
    if not flipy:
        ly = (Y + ay) % 256
    else:
        ly = (yext - 1 - Y + ay) % 256
    out = page_pixels(cap, page, layer, lx, ly, layer_base)
    # rowspan == 1: rows 0..255 are drawn; colspan == 1: columns 0..511
    out[256:, :] = 0
    return out


# ---------------------------------------------------------------- frame


def render(cap, stage="full", endian=">"):
    layer_base, sprite_base, back = colorbases(cap)
    pens = np.full((BMP_H, BMP_W), back, dtype=int)
    prio = np.zeros((BMP_H, BMP_W), dtype=int)
    # tilemap draws OR their priority into the bitmap (priority_mask 0xff keeps what is there)
    for layer, pr in ((3, 1), (2, 2), (1, 4)):
        p = draw_layer(cap, layer, layer_base[layer])
        m = p != 0
        pens[m] = p[m]
        prio[m] |= pr
    if stage == "full":
        from render_sprites import draw_sprites  # noqa: E402
        draw_sprites(cap, pens, prio, sprite_base)
    p = draw_layer(cap, 0, layer_base[0])
    m = p != 0
    pens[m] = p[m]
    pal = palette_rgb(cap, endian)
    img = pal[pens & 0x3fff]
    vis = img[VIS_Y0:VIS_Y1 + 1, VIS_X0:VIS_X1 + 1]
    if ORIENT.get(cap.set, "flipy") == "flipy":
        vis = vis[::-1, :]
    else:
        vis = vis[:, ::-1]
    return np.ascontiguousarray(vis)


def compare(model, ref, out_png):
    diff = np.any(model != ref, axis=2)
    n = int(diff.sum())
    vis = np.concatenate([model, ref, np.where(diff[:, :, None], np.array([255, 0, 255], np.uint8), ref // 3)], axis=1)
    Image.fromarray(vis.astype(np.uint8)).resize((vis.shape[1] * 2, vis.shape[0] * 2), Image.NEAREST).save(out_png)
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="+")
    ap.add_argument("--stage", default="full", choices=["tiles", "full"])
    ap.add_argument("--endian", default=">", choices=[">", "<"])
    a = ap.parse_args()
    rc = 0
    for name in a.capture:
        cap = Capture(name)
        model = render(cap, a.stage, a.endian)
        out = cap.dir / f"model_{a.stage}.png"
        n = compare(model, cap.ref, out)
        tot = model.shape[0] * model.shape[1]
        print(f"{name}: {a.stage}: {n} of {tot} pixels differ from MAME ({out.relative_to(REPO)})")
        rc |= n != 0
    return rc


if __name__ == "__main__":
    sys.exit(main())
