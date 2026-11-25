-- followteo.lua: walk UP (following Teo's lead direction), arm transition BPs,
-- screenshot every 40f. See if Teo leads through a door / transition fires.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/followteo/followteo.csv'
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
    local path = string.format('%s/ft_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
end

local function arm()
    local ok1, bp1 = pcall(PCSX.addBreakpoint, 0x800C4FE0, 'Exec', 4, 'ft_dispatcher', function()
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            local tag = bit.band(tonumber(r.GPR.n.a0), 0xFFFF)
            local ra = bit.band(tonumber(r.GPR.n.ra), 0xFFFFFFFF)
            log('DISP', string.format('tag=%04x ra=%08x', tag, ra))
        end
    end)
    log('bp', 'dispatcher=' .. tostring(ok1)); _G.FT_BP1 = bp1
    local ok2, bp2 = pcall(PCSX.addBreakpoint, 0x80179BEC, 'Write', 1, 'ft_bec', function()
        log('BEC_WRITE', '')
    end)
    log('bp', 'bec=' .. tostring(ok2)); _G.FT_BP2 = bp2
    local ok3, bp3 = pcall(PCSX.addBreakpoint, 0x80179CB8, 'Write', 4, 'ft_mq', function()
        log('MQ_WRITE', '')
    end)
    log('bp', 'mq=' .. tostring(ok3)); _G.FT_BP3 = bp3
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
        PAD.setOverride(B.UP)
        return
    end
    if not loaded then return end
    local t = frame - 60
    if t % 40 == 0 and t <= 400 then
        shot(string.format('t%03d', t))
    end
    if t >= 420 then
        PAD.clearOverride(B.UP)
        shot('end')
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame > 3000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.FOLLOWTEO_ANCHOR = vl
log('start', 'followteo')
