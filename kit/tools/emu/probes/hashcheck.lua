-- hashcheck.lua: load ingame then worldmap states, hash key regions.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/hc/hc.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end

local function hash_region(base, len)
    local h1, h2 = 0, 0
    for i = 0, len - 1 do
        local b = u8(base + i)
        h1 = bit.band(h1 * 31 + b, 0xFFFFFFFF)
        h2 = bit.bxor(h2, bit.lshift(b, bit.band(i, 24)))
    end
    return string.format('%08x:%08x', h1, bit.band(h2, 0xFFFFFFFF))
end

local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%s,%s\n', e, tostring(d or ''))); logf:flush() end

local frame, done, stage = 0, false, 0
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and stage == 0 then
        stage = 1
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        return
    end
    if frame == 120 and stage == 1 then
        stage = 2
        log('ingame_entries', hash_region(0x80179F08, 4096))
        log('ingame_streambuf', hash_region(0x801F0000, 4096))
        log('ingame_bf', string.format('bf1=%d bf3=%d', u8(0x80179BEB), u8(0x80179BF3)))
        local f = Support.File.open(FIXDIR .. '/worldmap.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        return
    end
    if frame == 180 and stage == 2 then
        stage = 3
        log('worldmap_entries', hash_region(0x80179F08, 4096))
        log('worldmap_streambuf', hash_region(0x801F0000, 4096))
        log('worldmap_bf', string.format('bf1=%d bf3=%d', u8(0x80179BEB), u8(0x80179BF3)))
        -- also check the second stream buffer and a bit deeper
        log('worldmap_streambuf2', hash_region(0x801F4000, 4096))
        log('worldmap_entries8k', hash_region(0x8017A908, 4096))
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.HC_ANCHOR = vl
log('start', 'hashcheck')
