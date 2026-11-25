-- poshunt.lua: find hero position in RAM via entry diffs while walking.
-- Dumps 0x80179F08 (8KB parsed entries) at rest, after LEFT, after UP.
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/poshunt/poshunt.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
os.execute('mkdir -p "' .. OUTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local function dump_region(path, base, len)
    local f = assert(io.open(path, 'wb'))
    local chunks = {}
    for i = 0, len - 1, 4096 do
        local n = math.min(4096, len - i)
        chunks[#chunks+1] = ffi.string(RAMB + (base - 0x80000000) + i, n)
    end
    f:write(table.concat(chunks))
    f:close()
end

local frame, done = 0, false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 then
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('load', 'ingame')
        return
    end
    if frame == 120 then
        dump_region(OUTDIR .. '/entries_rest.bin', 0x80179F08, 8192)
        log('dump', 'rest')
        PAD.setOverride(B.LEFT)
        return
    end
    if frame == 240 then
        PAD.clearOverride(B.LEFT)
        dump_region(OUTDIR .. '/entries_left.bin', 0x80179F08, 8192)
        log('dump', 'after LEFT 120f')
        PAD.setOverride(B.UP)
        return
    end
    if frame == 360 then
        PAD.clearOverride(B.UP)
        dump_region(OUTDIR .. '/entries_up.bin', 0x80179F08, 8192)
        log('dump', 'after UP 120f')
        done = true; logf:close(); PCSX.quit(0)
        return
    end
    if frame > 2000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.POSHUNT_ANCHOR = vl
log('start', 'poshunt')
