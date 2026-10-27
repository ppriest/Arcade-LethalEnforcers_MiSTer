-- SPDX-License-Identifier: GPL-3.0-or-later
-- Which K056832 VRAM pages Lethal Enforcers writes, and how far into each.
-- Driven by scripts/mame_vram_pages.py.
--
--   CORE_OUT     output directory
--   CORE_TAG     output filename prefix
--   VP_FRAMES    frames to run
--   VP_COIN      frame of the first coin (0 = attract only); two coins, then Start
--
-- The CPU reaches VRAM through the bank4000 window, bank space 0x2000-0x3fff
-- with CBNK=0: four 2 KB planes (code lo, code hi, attr lo, attr hi), one byte
-- per tile per plane. The page they land in is change_rambank()'s
-- (k054156_k054157_k056832.cpp): register 0x19, or page 16 (external line
-- scroll) while register 0 bit 1 is set. Registers are written a byte at a
-- time through k056832_device::write: main 0x4000+2n is the high byte of
-- word n, 0x4001+2n the low byte.

local OUT    = os.getenv("CORE_OUT") or "."
local TAG    = os.getenv("CORE_TAG") or "vram"
local FRAMES = tonumber(os.getenv("VP_FRAMES") or "3600")
local COIN   = tonumber(os.getenv("VP_COIN") or "0")

local mach = manager.machine
local main = mach.devices[":maincpu"].spaces["program"]
local bank = mach.devices[":bank4000"].spaces["program"]

local regs = {}
for i = 0, 0x1f do regs[i] = 0 end

local function page()
    if (regs[0] & 0x02) ~= 0 then return 16 end
    local b = regs[0x19]
    return ((b >> 1) & 0xc) | (b & 3)
end

-- per page: writes, lowest and highest tile index, and a 2048-bit map of tiles
local pages = {}
local function note(p, tile)
    local e = pages[p]
    if not e then e = { n = 0, lo = tile, hi = tile, seen = {}, count = 0 }; pages[p] = e end
    e.n = e.n + 1
    if tile < e.lo then e.lo = tile end
    if tile > e.hi then e.hi = tile end
    if not e.seen[tile] then e.seen[tile] = true; e.count = e.count + 1 end
end

_G.__vp_taps = {
    main:install_write_tap(0x4000, 0x403f, "vp_regs", function(offset, data, mask)
        local o = offset - 0x4000
        local w = o >> 1
        if (o & 1) == 0 then regs[w] = (regs[w] & 0x00ff) | ((data & 0xff) << 8)
        else regs[w] = (regs[w] & 0xff00) | (data & 0xff) end
        return data
    end),
    bank:install_write_tap(0x2000, 0x3fff, "vp_vram", function(offset, data, mask)
        note(page(), offset & 0x7ff)
        return data
    end),
}

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local f_coin, f_start, f_fire = field("Coin 1"), field("1 Player Start"), field("P1 Button 1")
local f_gx, f_gy = field("Lightgun X"), field("Lightgun Y")

local n = 0
emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 then
        if f_coin then f_coin:set_value(((n >= COIN and n < COIN + 6) or (n >= COIN + 20 and n < COIN + 26)) and 1 or 0) end
        if f_start then f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0) end
        if n > COIN + 120 then
            if f_fire then f_fire:set_value((n % 12) < 3 and 1 or 0) end
            if f_gx then pcall(function() f_gx:set_value((n * 7) % 256) end) end
            if f_gy then pcall(function() f_gy:set_value((n * 3) % 256) end) end
        end
    end
    if n == FRAMES then
        local f = assert(io.open(string.format("%s/%s_vram_pages.txt", OUT, TAG), "w"))
        f:write("# page writes tiles_touched lowest_tile highest_tile (tile = byte offset in a 2 KB plane)\n")
        local keys = {}
        for p in pairs(pages) do keys[#keys + 1] = p end
        table.sort(keys)
        for _, p in ipairs(keys) do
            local e = pages[p]
            f:write(string.format("%d %d %d 0x%03x 0x%03x\n", p, e.n, e.count, e.lo, e.hi))
        end
        f:close()
        pcall(function() mach.video:snapshot() end)
        mach:exit()
    end
end)
