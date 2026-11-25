-- door_transition.lua: walk hero UP through palace door, watch state machine
-- Natural area transition to document level loading

local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/door'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local state = 0
local done = false
local last_sm = -1
local last_mode = -1
local last_res = -1

local SM_STATE = 0x80179C04
local AREA_MODE = 0x80179CB8
local RES_IDX = 0x80179BF3
local REQ_FLAG = 0x80179BEB

local function rb(addr) return RAM[addr - 0x80000000] end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        wf:writeMoveSlice(ss.data)
        wf:close()
        PCSX.log('door: screenshot ' .. tag)
    end
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    -- Continuously monitor state machine during walk
    if state >= 2 then
        local sm = rb(SM_STATE)
        local mode = rb(AREA_MODE)
        local res = rb(RES_IDX)
        if sm ~= last_sm or mode ~= last_mode or res ~= last_res then
            PCSX.log(string.format('door: f=%d SM=0x%02X MODE=0x%02X RES=%d REQ=%d',
                frame, sm, mode, res, rb(REQ_FLAG)))
            last_sm, last_mode, last_res = sm, mode, res
        end
    end
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        PCSX.log(string.format('door: start SM=0x%02X MODE=0x%02X RES=%d',
            rb(SM_STATE), rb(AREA_MODE), rb(RES_IDX)))
        shot('start')
        state = 1
    elseif state == 1 and frame == 120 then
        -- Walk UP toward the doors (north end of palace)
        -- Hero (green) is at right side, need to go up
        PCSX.log('door: walking UP toward doors')
        PAD.setOverride(B.UP)
        state = 2
    elseif state == 2 and frame == 420 then
        -- 5 seconds of UP movement
        PAD.clearOverride(B.UP)
        shot('after_up')
        PCSX.log('door: trying UP+RIGHT diagonal (toward stairs/door)')
        PAD.setOverride(B.UP)
        -- Can't do diagonal with single override, try RIGHT then UP
        state = 3
    elseif state == 3 and frame == 600 then
        PAD.clearOverride(B.UP)
        shot('final')
        PCSX.log(string.format('door: end SM=0x%02X MODE=0x%02X RES=%d',
            rb(SM_STATE), rb(AREA_MODE), rb(RES_IDX)))
        done = true
        PCSX.quit(0)
    elseif frame > 900 then
        done = true
        PCSX.quit(0)
    end
end)
