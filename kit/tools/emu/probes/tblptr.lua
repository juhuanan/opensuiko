-- tblptr.lua: read the draw-list table pointers in ingame state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/tp/tp.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
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
    local t1 = u32(0x8017BF98)  -- 24-byte table ptr (drawlist_a_build)
    local t2 = u32(0x8018BE20)  -- struct ptr
    log('ptr_8017BF98', string.format('%08x', t1))
    log('ptr_8018BE20', string.format('%08x', t2))
    -- dump first 3 entries of 24 bytes at t1
    local phys = bit.band(t1, 0x1FFFFFFF)
    for e = 0, 2 do
        local bytes = {}
        for i = 0, 23 do bytes[#bytes+1] = string.format('%02x', u8(phys + e*24 + i)) end
        log('entry'..e, table.concat(bytes, ' '))
    end
    -- also dump first 24 bytes at 0x80179F08 for comparison
    local b2 = {}
    for i = 0, 23 do b2[#b2+1] = string.format('%02x', u8(0x80179F08 + i)) end
    log('at_80179F08', table.concat(b2, ' '))
    done = true; logf:close(); PCSX.quit(0)
end)
_G.TP_ANCHOR = vl
