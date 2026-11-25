-- cbcheck.lua: read per-frame callback pointer in ingame state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/cb/cb.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local frame = 0
local done, loaded = false, false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('cb', string.format('*(0x8017DA90)=%08x', u32(0x8017DA90)))
        -- try breakpoint on the actual callback
        local cb = u32(0x8017DA90)
        local ok, bp = pcall(PCSX.addBreakpoint, cb, 'Exec', 4, 'cb_hit', function()
            log('cb_hit', string.format('callback %08x executed', cb))
        end)
        if not ok then log('bp_fail', 'cb') end
        _G.CB_BP = bp
        return
    end
    if not loaded then return end
    if frame >= 300 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.CB_ANCHOR = vl
log('start', 'cbcheck')
