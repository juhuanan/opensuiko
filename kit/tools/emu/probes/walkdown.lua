-- walkdown.lua: walk DOWN from start, screenshot every 20f to see what happens.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/walkdown/walkdown.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local path = string.format('%s/wd_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
end

local done = false
local loaded = false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('load', 'ingame')
        shot('start')
        PAD.setOverride(B.DOWN)
        return
    end
    if not loaded then return end
    local t = frame - 60
    if t % 20 == 0 and t <= 200 then
        shot(string.format('t%03d', t))
        log('shot', t)
    end
    if t >= 220 then
        PAD.clearOverride(B.DOWN)
        shot('end')
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 3000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.WALKDOWN_ANCHOR = vl
log('start', 'walkdown')
