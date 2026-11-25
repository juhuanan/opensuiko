-- statetest.lua: try hallway.pcsxstate instead, test UP movement.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/statetest/statetest.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local path = string.format('%s/%s.raw', SHOTDIR, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    logf:write('shot ' .. tag .. '\n'); logf:flush()
end

local done = false
local loaded = false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/hallway.pcsxstate')
        local ok, err = pcall(function() PCSX.loadSaveState(f) end)
        logf:write('load hallway: ' .. tostring(ok) .. ' ' .. tostring(err) .. '\n')
        f:close()
        shot('start')
        return
    end
    if not loaded then return end
    local t = frame - 60
    if t == 5 then
        PAD.setOverride(B.UP)
        logf:write('up set\n'); logf:flush()
    end
    if t == 45 then
        PAD.clearOverride(B.UP)
        shot('t45')
    end
    if t >= 50 then
        shot('end')
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.STATETEST_ANCHOR = vl
