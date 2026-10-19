-- The Z80's writes to the 054539 (0xf800-0xfa2f) and its reads of 0x22d, from power-on:
-- "W <sample> <reg> <data>", "R <sample> 22d 00", <sample> the 48 kHz sample index
-- (machine time * 48000). Exits at CORE_FRAMES. Coins and Start as audio_play.lua
-- (LC_COIN). scripts/check_k539.py drives it.
local COIN = tonumber(os.getenv("LC_COIN") or "400")
local last_frame = tonumber(os.getenv("CORE_FRAMES") or "460")
local out = io.open(os.getenv("CORE_OUT"), "w")
local space = manager.machine.devices[":soundcpu"].spaces["program"]
k539_tap = space:install_write_tap(0xf800, 0xfa2f, "k539w", function(offset, data, mask)
  local t = manager.machine.time:as_double()
  out:write(string.format("W %d %03x %02x\n", math.floor(t * 48000), offset - 0xf800, data & 0xff))
end)
-- reads of 0x22d move the chip's RAM/ROM pointer: "R <sample> 22d 00"
k539_rtap = space:install_read_tap(0xfa2d, 0xfa2d, "k539r", function(offset, data, mask)
  local t = manager.machine.time:as_double()
  out:write(string.format("R %d %03x 00\n", math.floor(t * 48000), offset - 0xf800))
end)
local function field(name)
  for _, port in pairs(manager.machine.ioport.ports) do
    local f = port.fields[name]
    if f then return f end
  end
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
-- the 054321's volume and enables, read each frame from its save items: "V <sample> <active> <volume>", hex
local k321 = manager.machine.devices[":k054321"]
local i_vol, i_act = emu.item(k321.items["0/m_volume"]), emu.item(k321.items["0/m_active"])
local v_last = ""
local n = 0
k539_sub = emu.add_machine_frame_notifier(function()
  n = n + 1
  local v = string.format("%02x %02x", i_act:read(0), i_vol:read(0))
  if v ~= v_last then
    out:write(string.format("V %d %s\n", math.floor(manager.machine.time:as_double() * 48000), v))
    v_last = v
  end
  local k = n - COIN
  if f_coin then f_coin:set_value((k >= 0 and k < 40 and k % 20 < 6) and 1 or 0) end
  if f_start then f_start:set_value((k >= 110 and k < 116) and 1 or 0) end
  if n >= last_frame then out:close(); print("CORE_CAPTURE_OK"); manager.machine:exit() end
end)
