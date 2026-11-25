-- verify_addrs.lua: load palace fixture, verify memory addresses
local ffi = require('ffi')
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local frame = 0
local done = false

local function rb(a) return RAM[a - 0x80000000] end
local function rl(a)
    local o = a - 0x80000000
    return RAM[o] + RAM[o+1]*256 + RAM[o+2]*65536 + RAM[o+3]*16777216
end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        PCSX.log('verify: state loaded')
    elseif frame == 120 then
        PCSX.log(string.format('verify: RES_IDX (0x80179BF3) = %d', rb(0x80179BF3)))
        PCSX.log(string.format('verify: .8 ptr (0x8017BFC0) = 0x%08X', rl(0x8017BFC0)))
        -- Try alternative: maybe the base is different?
        -- Scan for the .8 magic or known values
        done = true
        PCSX.quit(0)
    elseif frame > 300 then
        done = true
        PCSX.quit(0)
    end
end)
