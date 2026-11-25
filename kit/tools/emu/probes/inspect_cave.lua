-- inspect_cave.lua: load cave state, dump area info
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local frame = 0
local done = false

local function rb(a) return RAM[a - 0x80000000] end
local function rw(a) 
    return RAM[a - 0x80000000] + RAM[a - 0x80000000 + 1] * 256
end
local function rl(a)
    return RAM[a - 0x80000000] + RAM[a - 0x80000000 + 1] * 256 +
           RAM[a - 0x80000000 + 2] * 65536 + RAM[a - 0x80000000 + 3] * 16777216
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        PCSX.log('inspect: state loaded')
    elseif frame == 120 then
        PCSX.log(string.format('inspect: RES_IDX (0x80179BF3) = %d', rb(0x80179BF3)))
        PCSX.log(string.format('inspect: SEQ (0x80179C02) = %d', rb(0x80179C02)))
        PCSX.log(string.format('inspect: SM (0x80179C04) = 0x%02X', rb(0x80179C04)))
        PCSX.log(string.format('inspect: .8 ptr (0x8017BFC0) = 0x%08X', rl(0x8017BFC0)))
        PCSX.log(string.format('inspect: table ptr (0x8017BF98) = 0x%08X', rl(0x8017BF98)))
        -- Check resource table entry for current index
        local idx = rb(0x80179BF3)
        local entry = 0x80164E68 + idx * 12
        PCSX.log(string.format('inspect: res[%d] LBA=0x%08X', idx, rl(entry)))
        done = true
        PCSX.quit(0)
    elseif frame > 300 then
        done = true
        PCSX.quit(0)
    end
end)
