-- teo_circle.lua: try CIRCLE button for Teo talk
-- User suggested trying circle

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/teo_circle'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local state = 0
local done = false
local hold_until = 0
local next_state = 0

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('teo_circle: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if hold_until > 0 and frame >= hold_until then
        PAD.clearOverride(B.LEFT)
        PAD.clearOverride(B.CIRCLE)
        hold_until = 0
        state = next_state
    end
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        state = 1
    elseif state == 1 and frame == 120 then
        -- Move hero (green, right) LEFT toward Teo (blue, left)
        PCSX.log('teo_circle: moving LEFT toward Teo')
        PAD.setOverride(B.LEFT)
        hold_until = frame + 60
        next_state = 2
        state = 99
    elseif state == 2 and frame == 220 then
        shot('near_teo')
        -- Press CIRCLE to talk
        PCSX.log('teo_circle: pressing CIRCLE')
        PAD.setOverride(B.CIRCLE)
        hold_until = frame + 12
        next_state = 3
        state = 99
    elseif state == 3 and frame == 300 then
        shot('after_circle')
        PCSX.log('teo_circle: checking for dialog')
        state = 4
    elseif state == 4 and frame == 400 then
        shot('final')
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
