-- eventtrace.lua: walk to guard, press X, trace event system.
-- Watches: dispatcher tags, 0x80179BEC writes, master queue writes.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/eventtrace/eventtrace.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
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
    local path = string.format('%s/ev_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
end

local function arm()
    -- dispatcher: log tag + caller
    local ok1, bp1 = pcall(PCSX.addBreakpoint, 0x800C4FE0, 'Exec', 4, 'ev_dispatcher', function()
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            local tag = bit.band(tonumber(r.GPR.n.a0), 0xFFFF)
            local ra = bit.band(tonumber(r.GPR.n.ra), 0xFFFFFFFF)
            log('DISP', string.format('tag=%04x ra=%08x', tag, ra))
        end
    end)
    log('bp', 'dispatcher=' .. tostring(ok1))
    _G.EV_BP1 = bp1
    -- 0x80179BEC write (transition target)
    local ok2, bp2 = pcall(PCSX.addBreakpoint, 0x80179BEC, 'Write', 1, 'ev_bec', function()
        local ok3, r = pcall(PCSX.getRegisters)
        if ok3 and r then
            log('BEC_WRITE', string.format('pc=%08x', bit.band(tonumber(r.GPR.n.epc or r.GPR.n.pc or 0), 0xFFFFFFFF)))
        else
            log('BEC_WRITE', 'pc=?')
        end
    end)
    log('bp', 'bec=' .. tostring(ok2))
    _G.EV_BP2 = bp2
    -- master queue 0x80179CB8 write
    local ok3, bp3 = pcall(PCSX.addBreakpoint, 0x80179CB8, 'Write', 4, 'ev_mq', function()
        log('MQ_WRITE', '')
    end)
    log('bp', 'mq=' .. tostring(ok3))
    _G.EV_BP3 = bp3
end

local done = false
local loaded = false
local phase = 0
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
    -- t=0..90: walk LEFT (up-left) toward guard area
    -- t=90..150: walk UP
    -- then X presses with different facings
    if t < 90 then
        PAD.setOverride(B.LEFT)
        phase = 1
    elseif t < 150 then
        PAD.clearOverride(B.LEFT); PAD.setOverride(B.UP)
        phase = 2
    elseif t < 160 then
        PAD.clearOverride(B.UP)
        phase = 3
    elseif t < 200 then
        -- face UP, press X
        if t % 20 < 10 then PAD.setOverride(B.CROSS) else PAD.clearOverride(B.CROSS) end
        phase = 4
        if t == 199 then shot('x_up') end
    elseif t < 240 then
        PAD.setOverride(B.DOWN)  -- face down
        if t % 20 < 10 then PAD.setOverride(B.CROSS) else PAD.clearOverride(B.CROSS) end
        phase = 5
        if t == 239 then shot('x_down') end
    elseif t < 280 then
        PAD.clearOverride(B.DOWN); PAD.setOverride(B.LEFT)
        if t % 20 < 10 then PAD.setOverride(B.CROSS) else PAD.clearOverride(B.CROSS) end
        phase = 6
        if t == 279 then shot('x_left') end
    elseif t < 320 then
        PAD.clearOverride(B.LEFT); PAD.setOverride(B.RIGHT)
        if t % 20 < 10 then PAD.setOverride(B.CROSS) else PAD.clearOverride(B.CROSS) end
        phase = 7
        if t == 319 then shot('x_right') end
    else
        for _, b in pairs({'UP','DOWN','LEFT','RIGHT','CROSS'}) do PAD.clearOverride(B[b]) end
        shot('end')
        log('done', 'eventtrace complete')
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 3000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.EVENTTRACE_ANCHOR = vl
log('start', 'eventtrace')
