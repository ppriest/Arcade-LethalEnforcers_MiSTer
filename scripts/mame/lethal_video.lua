-- Capture Lethal Enforcers' video state at a frame, for scripts/render_model.py.
-- Driven by scripts/lethal_capture.py.
--
--   CORE_OUT    capture directory (must exist)
--   CORE_FRAME  screen frame number to capture at
--   LC_COIN     frame of the first of two coins (0 = attract), then Start and firing
--
-- Where each piece comes from:
--   k056832_vram.bin  the K056832's m_videoram, all 17 pages, read as a save item
--                     (u16 little-endian, 0x1000 words a page; page 16 is the
--                     external line-scroll page)
--   k056832_regs.bin  m_regs (32 x u16 LE) and k056832_regsb.bin m_regsb (4 x u16 LE)
--   k056832_items.txt every smaller K056832 save item (m_x, m_dx, m_lsram_page,
--                     m_layer_offs, m_page_tile_mode, ...), little-endian hex
--   objbuf.bin        sprite RAM as the 053244's DMA last copied it: the 0x800 bytes
--                     are read through the bank4000 space (k053245_r: high byte
--                     first) at the moment the CPU writes 053244 register 6.
--                     The device's own m_buffer is not exposed to Lua.
--   objram.bin        sprite RAM at the capture frame, the same way
--   k053244_regs.bin  last value written to each of the 16 053244 registers
--   palette.bin       the 16 KB palette share, raw bytes
--   ctrl.bin          last value written to 0x40c4 (control2), 0x40c8 (PCU1),
--                     0x40cc (PCU2), 0x40d0 (PCU3)
--   reference.png     MAME's screenshot of the frame (screen orientation applied)

local OUT   = os.getenv("CORE_OUT") or "capture"
local FRAME = tonumber(os.getenv("CORE_FRAME") or "1200")
local COIN  = tonumber(os.getenv("LC_COIN") or "0")
local m     = manager.machine
local main  = m.devices[":maincpu"].spaces["program"]
local bank  = m.devices[":bank4000"].spaces["program"]

local function wr(name, bytes)
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(bytes)
    f:close()
end

local function obj_read()
    local t = {}
    for a = 0x1000, 0x17ff do t[#t + 1] = string.char(bank:read_u8(a) & 0xff) end
    return table.concat(t)
end

local objbuf = string.rep("\0", 0x800)
local dma_frame = -1
local objregs = {}
for i = 0, 15 do objregs[i] = 0 end
local ctrl = { [0] = 0, 0, 0, 0 }

_G.__lc_taps = {
    bank:install_write_tap(0x0840, 0x084f, "lc_objregs", function(offset, data, mask)
        local r = offset & 0xf
        objregs[r] = data & 0xff
        if r == 6 then
            objbuf = obj_read()
            dma_frame = m.screens[":screen"]:frame_number()
        end
        return data
    end),
    main:install_write_tap(0x40c4, 0x40d0, "lc_ctrl", function(offset, data, mask)
        local i = ({ [0x40c4] = 0, [0x40c8] = 1, [0x40cc] = 2, [0x40d0] = 3 })[offset]
        if i then ctrl[i] = data & 0xff end
        return data
    end),
}

local function item_bytes(tag, name)
    local d = assert(m.devices[tag], "no device " .. tag)
    local id = assert(d.items["0/" .. name], "no item " .. name .. " on " .. tag)
    local it = emu.item(id)
    return it:read_block(0, it.size * it.count)
end

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local f_coin, f_start, f_fire = field("Coin 1"), field("1 Player Start"), field("P1 Button 1")
local f_gx, f_gy = field("Lightgun X"), field("Lightgun Y")

local done = false
_G.__lc_frame = emu.add_machine_frame_notifier(function()
    if done then return end
    local scr = m.screens[":screen"]
    local n = scr:frame_number()
    if COIN > 0 then
        local k = n - COIN
        if f_coin then f_coin:set_value((k >= 0 and k < 40 and k % 20 < 6) and 1 or 0) end
        if f_start then f_start:set_value((k >= 110 and k < 116) and 1 or 0) end
        if k > 140 then
            if f_fire then f_fire:set_value((n % 12) < 3 and 1 or 0) end
            if f_gx then pcall(function() f_gx:set_value((n * 7) % 256) end) end
            if f_gy then pcall(function() f_gy:set_value((n * 3) % 256) end) end
        end
    end
    if n < FRAME then return end
    done = true

    wr("k056832_vram.bin", item_bytes(":k056832", "m_videoram"))
    wr("k056832_regs.bin", item_bytes(":k056832", "m_regs"))
    wr("k056832_regsb.bin", item_bytes(":k056832", "m_regsb"))
    -- every other K056832 item, for the layer geometry MAME derives from the
    -- registers: k056832_items.txt, one "name size count hexbytes" line each
    local fi = assert(io.open(OUT .. "/k056832_items.txt", "w"))
    for k, id in pairs(m.devices[":k056832"].items) do
        local it = emu.item(id)
        if it.size * it.count <= 4096 then
            local b = it:read_block(0, it.size * it.count)
            local name = k:gsub("^0/", "")
            local hex = b:gsub(".", function(c) return string.format("%02x", c:byte()) end)
            fi:write(string.format("%s %d %d %s", name, it.size, it.count, hex), "\n")
        end
    end
    fi:close()
    wr("objbuf.bin", objbuf)
    wr("objram.bin", obj_read())
    local t = {}
    for i = 0, 15 do t[#t + 1] = string.char(objregs[i]) end
    wr("k053244_regs.bin", table.concat(t))
    local pal = m.memory.shares[":palette"]
    t = {}
    for a = 0, pal.size - 1 do t[#t + 1] = string.char(pal:read_u8(a) & 0xff) end
    wr("palette.bin", table.concat(t))
    wr("ctrl.bin", string.char(ctrl[0], ctrl[1], ctrl[2], ctrl[3]))
    scr:snapshot(OUT .. "/reference.png")

    local f = assert(io.open(OUT .. "/manifest.txt", "w"))
    f:write("set ", m.system.name, "\n")
    f:write("mame ", emu.app_version(), "\n")
    f:write("frame ", tostring(n), "\n")
    f:write("dma_frame ", tostring(dma_frame), "\n")
    f:write("screen ", tostring(scr.width), "x", tostring(scr.height), "\n")
    f:close()
    print("CORE_CAPTURE_OK " .. OUT)
    m:exit()
end)
