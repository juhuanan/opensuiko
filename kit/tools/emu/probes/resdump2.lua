-- resdump2.lua — dump raw 12-byte resource table entries from ingame state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = (os.getenv('SUIKODEN_OUT') or '/tmp/rd/rd.csv')
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function u16(a)
    local b = bit.band(a, 0x1FFFFFFF)
    return tonumber(RAMB[b]) + tonumber(RAMB[b+1]) * 256
end
local function u32(a)
    local b = bit.band(a, 0x1FFFFFFF)
    return tonumber(RAMB[b]) + tonumber(RAMB[b+1])*256 + tonumber(RAMB[b+2])*65536 + tonumber(RAMB[b+3])*16777216
end
local frame, done, loaded = 0, false, false
local logf = assert(io.open(OUT, 'w'))
VsyncListener = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 30 and not loaded then
        loaded = true
        local f = Support.File.open('/home/hatch/workspace/suikoden/kit/tools/emu/fixtures/ingame.pcsxstate')
        if f then pcall(function() PCSX.loadSaveState(f) end); f:close() end
        return
    end
    if loaded and frame == 120 then
        for idx = 0, 66 do
            local e = 0x80164E68 + idx * 12
            local b = {}
            for i = 0, 11 do b[#b+1] = string.format('%02X', u8(e + i)) end
            logf:write(string.format('%d,%s,lba=%d\n', idx, table.concat(b), u32(e)))
        end
        logf:close(); done = true; PCSX.quit(0)
    end
end)
_G.RD_ANCHOR = VsyncListener
