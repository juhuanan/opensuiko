-- talk2.lua: move around and mash CROSS, looking for dialogue.
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/talk2.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local path = string.format('%s/t2_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
end

local done = false
local loaded = false
-- Phase 1: move to guard (DOWN+LEFT), Phase 2: mash CROSS, Phase 3: move around mashing
local phase = 0
local pt = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
        shot('start')
    end
    if not loaded then return end
    pt = pt + 1

    -- Clear all first
    for _, b in pairs({'DOWN','LEFT','RIGHT','UP','CROSS'}) do
        PAD.clearOverride(B[b])
    end

    if pt < 120 then
        -- Move DOWN+LEFT toward guard
        PAD.setOverride(B.DOWN); PAD.setOverride(B.LEFT)
    elseif pt < 200 then
        -- Mash CROSS
        if pt % 20 < 10 then PAD.setOverride(B.CROSS) end
        if pt == 199 then shot('mash1') end
    elseif pt < 320 then
        -- Move around: try different directions, mashing CROSS
        local dir = ({'UP','RIGHT','DOWN','LEFT'})[math.floor((pt-200)/30) % 4 + 1]
        PAD.setOverride(B[dir])
        if pt % 20 < 10 then PAD.setOverride(B.CROSS) end
    elseif pt < 400 then
        -- Final mash
        if pt % 20 < 10 then PAD.setOverride(B.CROSS) end
        if pt == 399 then shot('end') end
    else
        for _, b in pairs({'DOWN','LEFT','RIGHT','UP','CROSS'}) do
            PAD.clearOverride(B[b])
        end
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.T2_ANCHOR = vl
logf:write('start\n'); logf:flush()
