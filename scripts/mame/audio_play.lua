-- Coins and Start for an audio capture, as lethal_video.lua's LC_COIN sequence without
-- the firing: two coins from frame LC_COIN (6 frames each, 20 apart), Start 110 frames
-- after. Exits at CORE_FRAMES. scripts/audio_capture.py drives it with -wavwrite.
local COIN = tonumber(os.getenv("LC_COIN") or "400")
local last_frame = tonumber(os.getenv("CORE_FRAMES") or "1200")
local function field(name)
  for _, port in pairs(manager.machine.ioport.ports) do
    local f = port.fields[name]
    if f then return f end
  end
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local n = 0
audio_play_sub = emu.add_machine_frame_notifier(function()
  n = n + 1
  local k = n - COIN
  if f_coin then f_coin:set_value((k >= 0 and k < 40 and k % 20 < 6) and 1 or 0) end
  if f_start then f_start:set_value((k >= 110 and k < 116) and 1 or 0) end
  if n >= last_frame then print("CORE_CAPTURE_OK"); manager.machine:exit() end
end)
