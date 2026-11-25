-- areadump.lua: dump area system state from RAM.
-- Reads the area indices and resource table entries.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/areadump.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local FIXDIR = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
os.execute('mkdir -p "' .. OUTDIR .. '"')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function u8(a)
    local w = u32(bit.band(a, 0xFFFFFFFC))
    return bit.band(bit.rshift(w, bit.band(a, 3) * 8), 0xFF)
end

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
        logf:write(string.format('load ok=%s\n', tostring(ok)))
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
    end
    if loaded and frame == 90 then
        -- Dump area system state
        logf:write(string.format('pending_idx_801790B8=%d\n', u8(0x801790B8)))
        logf:write(string.format('request_flag_80179BEB=%d\n', u8(0x80179BEB)))
        logf:write(string.format('resource_idx_80179BF3=%d\n', u8(0x80179BF3)))
        logf:write(string.format('load_state_80179C04=%d\n', u8(0x80179C04)))
        logf:write(string.format('area_mode_80179CB8=%d\n', u8(0x80179CB8)))
        -- Dump resource table entries (0x80164E68, 12 bytes each)
        -- Entry format: likely LBA, size, dest
        local idx = u8(0x80179BF3)
        logf:write(string.format('--- resource table entry %d ---\n', idx))
        local base = 0x80164E68 + idx * 12
        for i = 0, 2 do
            logf:write(string.format('  word%d=0x%08X (%d)\n', i, u32(base + i*4), u32(base + i*4)))
        end
        -- Dump a few neighboring entries for context
        for j = -2, 2 do
            local k = idx + j
            if k >= 0 and k ~= idx then
                local b = 0x80164E68 + k * 12
                logf:write(string.format('entry %d: %08X %08X %08X\n', k,
                    u32(b), u32(b+4), u32(b+8)))
            end
        end
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 500 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.AD_ANCHOR = vl
