-- rendcheck.lua: check if overlay renderer 0x80131B90 runs every frame.
local frame = 0
local done, loaded = false, false
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/rc/rc.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end
local hits = 0
local function arm_bp()
    local ok, bp = pcall(PCSX.addBreakpoint, 0x80131B90, 'Exec', 4, 'renderer', function()
        hits = hits + 1
        if hits <= 5 then log('rend', 'hit ' .. hits) end
    end)
    if not ok then log('bp_fail', 'renderer') else log('bp_ok', 'renderer armed') end
    _G.RC_BP = bp
end
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', 'ingame')
        arm_bp()
        return
    end
    if not loaded then return end
    if frame == 300 then
        log('summary', 'hits=' .. hits)
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.RC_ANCHOR = vl
log('start', 'rendcheck')
