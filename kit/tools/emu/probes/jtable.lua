-- jtable.lua: dump jump table at 0x800C1998 from ingame state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/jt/jt.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a)
    local ok, v = pcall(function() return RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)] end)
    return ok and tonumber(v) or 0
end
local function norm(v) return bit.band(tonumber(v) or 0, 0xFFFFFFFF) end
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%s,%s\n', e, tostring(d or ''))); logf:flush() end
local frame, done, loaded = 0, false, false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        return
    end
    if not loaded or frame < 120 then return end
    for i = 0, 63 do
        local h = norm(u32(0x800C1998 + i*4))
        if h ~= 0 then
            log('handler', string.format('byte=%02x -> %08x', i, h))
        end
    end
    done = true; logf:close(); PCSX.quit(0)
end)
_G.JT_ANCH = vl
