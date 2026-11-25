-- resdump.lua: dump all 67 resource table entries.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/resdump.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local done = false
local loaded = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
    end
    if loaded and frame == 90 then
        logf:write('idx,lba,size,dest\n')
        for idx = 0, 66 do
            local b = 0x80164E68 + idx * 12
            logf:write(string.format('%d,%d,%d,0x%X\n', idx,
                u32(b), u32(b+4), u32(b+8)))
        end
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 500 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.RD_ANCHOR = vl
