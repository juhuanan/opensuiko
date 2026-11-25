-- geocheck.lua: check if VRAM or other regions change during forced load.
-- Compares GPU VRAM hash before/after.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/gc/gc.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local frame = 0
local done, loaded = false, false
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

-- Try to get VRAM via GPU API
local function vram_hash()
    local ok, vram = pcall(function() return PCSX.GPU.getVRAM() end)
    if not ok or not vram then return "no_vram_api" end
    -- vram is probably a table or userdata; try to hash it
    return "vram_exists"
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', vram_hash())
        -- List GPU API
        local apis = {}
        for k, v in pairs(PCSX.GPU) do apis[#apis+1] = k end
        log('gpu_api', table.concat(apis, ','))
        done = true; logf:close(); PCSX.quit(0)
        return
    end
end)
_G.GC_ANCHOR = vl
log('start', 'geocheck')
