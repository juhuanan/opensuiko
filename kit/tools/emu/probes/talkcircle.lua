-- talkcircle.lua: try CIRCLE (not X) for talk, near NPC start position.
-- Arms dispatcher/BEC/MQ breakpoints. Screenshots each attempt.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/talkcircle/talkcircle.csv'
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
    if not ok or not ss or not ss.data then log('shotfail', tag); return end
    local path = string.format('%s/tc_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
end

local function arm()
    local ok1, bp1 = pcall(PCSX.addBreakpoint, 0x800C4FE0, 'Exec', 4, 'tc_dispatcher', function()
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            local tag = bit.band(tonumber(r.GPR.n.a0), 0xFFFF)
            local ra = bit.band(tonumber(r.GPR.n.ra), 0xFFFFFFFF)
            log('DISP', string.format('tag=%04x ra=%08x', tag, ra))
        end
    end)
    log('bp', 'dispatcher=' .. tostring(ok1)); _G.TC_BP1 = bp1
    local ok2, bp2 = pcall(PCSX.addBreakpoint, 0x80179BEC, 'Write', 1, 'tc_bec', function()
        log('BEC_WRITE', '')
    end)
    log('bp', 'bec=' .. tostring(ok2)); _G.TC_BP2 = bp2
    local ok3, bp3 = pcall(PCSX.addBreakpoint, 0x80179CB8, 'Write', 4, 'tc_mq', function()
        log('MQ_WRITE', '')
    end)
    log('bp', 'mq=' .. tostring(ok3)); _G.TC_BP3 = bp3
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
        arm()
        shot('start')
        return
    end
    if not loaded then return end
    local t = frame - 60
    -- Phase 1 (t=0-120): mash CIRCLE from start position
    -- Phase 2 (t=120-180): walk DOWN toward NPC area
    -- Phase 3 (t=180-300): mash CIRCLE
    -- Phase 4 (t=300-360): walk LEFT, mash CIRCLE
    if t < 120 then
        if t % 20 < 10 then PAD.setOverride(B.CIRCLE) else PAD.clearOverride(B.CIRCLE) end
        if t == 119 then shot('circle_start') end
    elseif t < 180 then
        PAD.clearOverride(B.CIRCLE)
        PAD.setOverride(B.DOWN)
        if t == 179 then shot('moved_down') end
    elseif t < 300 then
        PAD.clearOverride(B.DOWN)
        if t % 20 < 10 then PAD.setOverride(B.CIRCLE) else PAD.clearOverride(B.CIRCLE) end
        if t == 299 then shot('circle_down') end
    elseif t < 360 then
        PAD.clearOverride(B.CIRCLE)
        PAD.setOverride(B.LEFT)
        if t % 20 < 10 then PAD.setOverride(B.CIRCLE) else PAD.clearOverride(B.CIRCLE) end
        if t == 359 then shot('circle_left') end
    else
        for _, b in pairs({'UP','DOWN','LEFT','RIGHT','CIRCLE','CROSS'}) do PAD.clearOverride(B[b]) end
        shot('end')
        log('done', 'talkcircle complete')
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 3000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.TALKCIRCLE_ANCHOR = vl
log('start', 'talkcircle')
