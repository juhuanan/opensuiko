-- setupdump.lua: dump the Area_RequestNext setup area.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/sd.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local loaded, done = false, false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        -- dump 0x80179C00..0x80179C30
        local parts = {}
        for a = 0x80179C00, 0x80179C30 do
            parts[#parts+1] = string.format('%02x', u8(a))
        end
        logf:write(string.format('60,setup,%s\n', table.concat(parts, ' ')))
        -- also 0x80179BF0..0x80179C00 and 0x801790B0..0x801790C0
        parts = {}
        for a = 0x80179BF0, 0x80179C00 do
            parts[#parts+1] = string.format('%02x', u8(a))
        end
        logf:write(string.format('60,req,%s\n', table.concat(parts, ' ')))
        logf:flush()
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.SD_ANCHOR = vl
