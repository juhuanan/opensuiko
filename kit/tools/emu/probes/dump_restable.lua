-- dump_restable.lua: dump resource table from palace fixture
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
local function log(m) PCSX.log('restbl: ' .. m) end

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if frame == 30 then
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('Palace loaded')
    elseif frame == 60 then
        -- Dump first 20 entries of resource table at 0x80164E68
        -- Each entry is 12 bytes: LBA (4), size (4), dest (4)? Or similar
        log('Resource table at 0x80164E68:')
        for i = 0, 19 do
            local entry = 0x80164E68 + i * 12
            local w0 = rl(entry)
            local w1 = rl(entry + 4)
            local w2 = rl(entry + 8)
            log(string.format('  [%2d] 0x%08X 0x%08X 0x%08X', i, w0, w1, w2))
        end
        -- Current index
        log(string.format('Current RES_IDX=%d', rb(0x80179BF3)))
        done = true
        PCSX.quit(0)
    elseif frame > 300 then
        done = true
        PCSX.quit(0)
    end
end)
