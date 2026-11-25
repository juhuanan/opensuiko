-- entrydiff.lua: dump parsed entries from ingame and worldmap states, save to files.
local ffi = require('ffi')
local bit = require('bit')
local OUTDIR = os.getenv('SUIKODEN_OUT') or '/tmp/ed'
OUTDIR = OUTDIR:match('^(.*)/[^/]*$') or '/tmp/ed'
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end

local function dump_region(path, base, len)
    local f = assert(io.open(path, 'wb'))
    for i = 0, len - 1 do
        f:write(string.char(u8(base + i)))
    end
    f:close()
end

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
        dump_region(OUTDIR .. '/ingame_entries.bin', 0x80179F08, 8192)
        dump_region(OUTDIR .. '/ingame_streamhead.bin', 0x801F0000, 4096)
        local f = Support.File.open(FIXDIR .. '/worldmap.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        return
    end
    if frame == 180 and stage == 2 then
        stage = 3
        dump_region(OUTDIR .. '/worldmap_entries.bin', 0x80179F08, 8192)
        dump_region(OUTDIR .. '/worldmap_streamhead.bin', 0x801F0000, 4096)
        done = true; PCSX.quit(0)
    end
end)
_G.ED_ANCHOR = vl
