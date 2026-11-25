-- fntable.lua: dump runtime function-pointer tables in ingame state.
-- 0x8017DA94: setup-function table (indexed by a0*4), called via jalr from 0x80131624
-- 0x8017DA90: callback table (0x80131724 stored at +a0*4 by 0x80131624)
-- Also: per-frame callback slot *(0x8017DA90), and a0 used at 0x80131624.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/ft/ft.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
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
    for i = 0, 15 do
        local s = u32(0x8017DA94 + i*4)
        local c = u32(0x8017DA90 + i*4)
        if s ~= 0 or c ~= 0 then
            log('tables', string.format('i=%d setup=%08x cb=%08x', i, norm(s), norm(c)))
        end
    end
    log('tblptr', string.format('%08x', norm(u32(0x8017BF98))))
    -- what is a0-relevant state? dump the area bytes
    local ab = {}
    for _, a in ipairs({0x80179BEB, 0x80179BEC, 0x80179BF3, 0x80179BF4}) do
        ab[#ab+1] = string.format('%08x=%02x', a, bit.band(u32(a), 0xFF))
    end
    log('areabytes', table.concat(ab, ' '))
    done = true; logf:close(); PCSX.quit(0)
end)
_G.FT_ANCHOR = vl
