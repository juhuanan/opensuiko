-- verify_xy.lua: confirm X/Y addresses
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())

local frame = 0
local done = false
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function rw(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256
end
local function log(m) PCSX.log('vxy: ' .. m) end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log(string.format('Start: X?=0x8017C00E=%d Y=0x8017C010=%d X?=0x8017C012=%d',
            rw(0x8017C00E), rw(0x8017C010), rw(0x8017C012)))
    elseif frame == 60 then
        PAD.setOverride(B.UP)
    elseif frame == 120 then
        PAD.clearOverride(B.UP)
        log(string.format('After UP: 0x8017C00E=%d 0x8017C010=%d 0x8017C012=%d',
            rw(0x8017C00E), rw(0x8017C010), rw(0x8017C012)))
        PAD.setOverride(B.RIGHT)
    elseif frame == 180 then
        PAD.clearOverride(B.RIGHT)
        log(string.format('After RIGHT: 0x8017C00E=%d 0x8017C010=%d 0x8017C012=%d',
            rw(0x8017C00E), rw(0x8017C010), rw(0x8017C012)))
        PAD.setOverride(B.DOWN)
    elseif frame == 240 then
        PAD.clearOverride(B.DOWN)
        log(string.format('After DOWN: 0x8017C00E=%d 0x8017C010=%d 0x8017C012=%d',
            rw(0x8017C00E), rw(0x8017C010), rw(0x8017C012)))
        PAD.setOverride(B.LEFT)
    elseif frame == 300 then
        PAD.clearOverride(B.LEFT)
        log(string.format('After LEFT: 0x8017C00E=%d 0x8017C010=%d 0x8017C012=%d',
            rw(0x8017C00E), rw(0x8017C010), rw(0x8017C012)))
        done = true
        PCSX.quit(0)
    elseif frame > 400 then
        done = true
        PCSX.quit(0)
    end
end)
