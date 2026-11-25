-- trackpos.lua: per-frame tracking of entries 240-290 while walking LEFT.
-- Finds the true hero X/Y signal.
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/trackpos/trackpos.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
os.execute('mkdir -p "' .. OUTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON
local function u16(a)
    return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) + tonumber(RAMB[bit.band(a+1, 0x1FFFFFFF)])*256
end

local frame, done = 0, false
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,e263_0,e50_8,e50_16lo\n')

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 then
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        return
    end
    if frame == 90 then PAD.setOverride(B.LEFT) end
    if frame >= 90 and frame <= 330 and frame % 6 == 0 then
        local e263 = u16(0x80179F08 + 263*24)
        local e50_8 = u16(0x80179F08 + 50*24 + 8)
        local e50_16 = u16(0x80179F08 + 50*24 + 16)
        logf:write(string.format('%d,%d,%d,%d\n', frame, e263, e50_8, e50_16))
    end
    if frame == 340 then
        PAD.clearOverride(B.LEFT)
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 2000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.TRACKPOS_ANCHOR = vl
