-- wander_palace.lua: load palace, walk around, dump position and watch for transitions
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/wander'
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local phase = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rb(a) return RAM[a - 0x80000000] end
local function rw(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256
end
local function rl(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256 + RAM[o+2]*65536 + RAM[o+3]*16777216
end
local function log(tag, msg) PCSX.log('wander: [' .. tag .. '] ' .. msg) end

local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if ok and ss and ss.data then
        local wf = Support.File.open(OUT .. '_' .. tag .. '.raw', 'TRUNCATE')
        if wf then wf:writeMoveSlice(ss.data); wf:close() end
    end
end

-- Hero position is likely at a known address. Let's try to find it by
-- watching memory changes while moving. For now, dump a range.
local function dump_mem(tag)
    -- Dump key addresses
    log(tag, string.format('RES_IDX=%d .8ptr=0x%08X', rb(0x80179BF3), rl(0x8017BFC0)))
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('init', 'Palace loaded')
        dump_mem('init')
        shot('00_start')
    elseif frame == 120 then
        -- Walk UP for 3 seconds (180 frames)
        log('move', 'Walking UP')
        PAD.setOverride(B.UP)
    elseif frame == 300 then
        PAD.clearOverride(B.UP)
        log('move', 'Stop, dump')
        dump_mem('after_up')
        shot('01_after_up')
    elseif frame == 360 then
        -- Walk RIGHT
        log('move', 'Walking RIGHT')
        PAD.setOverride(B.RIGHT)
    elseif frame == 540 then
        PAD.clearOverride(B.RIGHT)
        log('move', 'Stop, dump')
        dump_mem('after_right')
        shot('02_after_right')
    elseif frame == 600 then
        -- Walk DOWN
        log('move', 'Walking DOWN')
        PAD.setOverride(B.DOWN)
    elseif frame == 780 then
        PAD.clearOverride(B.DOWN)
        log('move', 'Stop, dump')
        dump_mem('after_down')
        shot('03_after_down')
        log('done', 'Wander complete')
        done = true
        PCSX.quit(0)
    elseif frame > 1000 then
        done = true
        PCSX.quit(0)
    end
end)
