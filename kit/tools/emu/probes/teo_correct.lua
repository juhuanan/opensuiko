-- teo_correct.lua: hero (green, right) moves LEFT toward Teo (blue, left), press LEFT to talk
-- CORRECTED: Teo is blue armor left, Hero is green hair right (player controls green)

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/teo_correct'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local state = 0
local done = false

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('teo_correct: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        state = 1
    elseif state == 1 and frame == 120 then
        -- Hero (green) is at right (X~230), Teo (blue) at left (X~170)
        -- Move hero LEFT toward Teo (but not too far, stop before overlapping)
        PCSX.log('teo_correct: moving hero LEFT toward Teo')
        PAD.setOverride(B.LEFT)
        state = 2
    elseif state == 2 and frame == 180 then
        -- Stop moving (60 frames of left movement)
        PAD.clearOverride(B.LEFT)
        shot('near_teo')
        PCSX.log('teo_correct: pressing LEFT to talk to Teo (Teo is left of hero)')
        -- Press LEFT (direction toward Teo) to initiate talk
        PAD.setOverride(B.LEFT)
        state = 3
    elseif state == 3 and frame == 192 then
        -- Release after 12 frames (tap)
        PAD.clearOverride(B.LEFT)
        state = 4
    elseif state == 4 and frame == 250 then
        shot('after_talk')
        PCSX.log('teo_correct: checking for dialog')
        state = 5
    elseif state == 5 and frame == 350 then
        shot('dialog_check')
        -- Try pressing CROSS as well (in case it's the talk button)
        PCSX.log('teo_correct: trying CROSS')
        PAD.setOverride(B.CROSS)
        state = 6
    elseif state == 6 and frame == 362 then
        PAD.clearOverride(B.CROSS)
        state = 7
    elseif state == 7 and frame == 450 then
        shot('after_cross')
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
