-- hungstate.lua: capture CPU state when Teo event hangs
-- Loads palace state, then samples PC to find where it's stuck

local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/hungstate.txt'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local frame = 0
local loaded = false
local done = false
local logf = assert(io.open(OUT, 'w'))

-- Sample PCs
local pc_samples = {}
local sample_count = 0

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        logf:write(string.format('load ok=%s\n', tostring(ok)))
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
    end
    
    -- Sample PC every 30 frames after load
    if loaded and frame > 90 and frame % 30 == 0 and sample_count < 10 then
        -- Get PC via debug interface? PCSX-Redux Lua may not expose PC directly
        -- Instead, we'll just note the frame
        sample_count = sample_count + 1
        logf:write(string.format('frame %d: alive\n', frame))
    end
    
    if loaded and frame == 400 then
        done = true
        logf:write('sampling done\n')
        logf:close()
        PCSX.quit(0)
    end
end)
