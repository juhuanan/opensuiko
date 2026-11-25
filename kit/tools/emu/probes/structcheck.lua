-- structcheck.lua: dump area struct pointers from ingame state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/sc/sc.csv'
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
    for _, a in ipairs({0x8017C108, 0x8017C164, 0x8017BF98, 0x8017BFC0, 0x8017AAE4}) do
        local p = norm(u32(a))
        log('ptr', string.format('%08x -> %08x', a, p))
        if p ~= 0 then
            -- dump first 4 words at target
            local ws = {}
            for i = 0, 3 do ws[#ws+1] = string.format('%08x', norm(u32(p + i*4))) end
            log('data', string.format('%08x: %s', p, table.concat(ws, ' ')))
        end
    end
    done = true; logf:close(); PCSX.quit(0)
end)
_G.SC_ANCH = vl
