-- hiscore.dat's ranges, read each frame from power-on: prints "HS <frame> <hex>" whenever
-- they change, then exits at CORE_FRAMES. scripts/hs_ready.py drives it.
local ranges = {}
for a, n in string.gmatch(os.getenv("HS_RANGES") or "", "(%x+):(%x+)") do
  ranges[#ranges + 1] = { tonumber(a, 16), tonumber(n, 16) }
end
local last_frame = tonumber(os.getenv("CORE_FRAMES") or "1800")
local space = manager.machine.devices[":maincpu"].spaces["program"]
local f, prev = 0, nil
hs_watch_sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  local t = {}
  for _, r in ipairs(ranges) do
    for i = 0, r[2] - 1 do t[#t + 1] = string.format("%02x", space:read_u8(r[1] + i)) end
  end
  local s = table.concat(t)
  if s ~= prev then print(string.format("HS %d %s", f, s)); prev = s end
  if f >= last_frame then print("CORE_CAPTURE_OK"); manager.machine:exit() end
end)
