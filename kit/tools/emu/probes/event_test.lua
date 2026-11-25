-- event_test.lua: see if Vsync fires during boot
local frame = 0
local done = false

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame % 1000 == 0 then
        PCSX.log('etest: frame ' .. frame)
    end
    if frame >= 5000 then
        PCSX.log('etest: reached 5000, done')
        done = true
        PCSX.quit(0)
    end
end)
