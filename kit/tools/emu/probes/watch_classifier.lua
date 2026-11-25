-- watch_classifier.lua: breakpoint on classifier, see when it runs
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/watch'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local frame = 0
local state = 0
local done = false
local hits = 0

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local bp_ok = pcall(PCSX.addBreakpoint, 0x8012ED84, 'Exec', 4, 'classifier', function()
    hits = hits + 1
    if hits <= 5 then
        PCSX.log(string.format('watch: CLASSIFIER HIT #%d at frame %d', hits, frame))
    end
end)
PCSX.log('watch: classifier breakpoint set: ' .. tostring(bp_ok))

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        state = 1
    elseif state == 1 and frame == 180 then
        -- Open menu (SQUARE) to trigger redraw
        PCSX.log('watch: pressing SQUARE (menu)')
        PAD.setOverride(B.SQUARE)
        state = 2
    elseif state == 2 and frame == 200 then
        PAD.clearOverride(B.SQUARE)
        state = 3
    elseif state == 3 and frame == 300 then
        -- Close menu (CIRCLE)
        PCSX.log('watch: pressing CIRCLE (close menu)')
        PAD.setOverride(B.CIRCLE)
        state = 4
    elseif state == 4 and frame == 320 then
        PAD.clearOverride(B.CIRCLE)
        state = 5
    elseif state == 5 and frame == 600 then
        PCSX.log(string.format('watch: done, classifier hits=%d', hits))
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
