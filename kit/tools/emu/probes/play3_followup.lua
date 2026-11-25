-- play3_followup.lua: segment 3. Walk UP to Teo, tap DOWN to face him,
-- mash CIRCLE to talk. Screenshots throughout.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play3/play2.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local queue = {}
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,event,detail\n')
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local function after(n, fn) queue[#queue + 1] = { at = frame + n, fn = fn } end
local function wait(n, next) after(n, next) end

local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shot_fail', tag); return end
    local path = string.format('%s/p3_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/p3_%03d_%s.meta', SHOTDIR, shot_n, tag), 'w')
    if mf then mf:write('width=320 height=240 bpp=BPP_16\n'); mf:close() end
    log('shot', tag)
end

local function tap(btn, hold, next)
    PAD.setOverride(btn)
    wait(hold, function()
        PAD.clearOverride(btn)
        wait(10, next)
    end)
end

local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local function arm()
    local ok1, bp1 = pcall(PCSX.addBreakpoint, 0x800C4FE0, 'Exec', 4, 'p3_disp',
        function()
            local ok2, r = pcall(PCSX.getRegisters)
            if ok2 and r then
                log('DISP', string.format('tag=%04x', bit.band(tonumber(r.GPR.n.a0), 0xFFFF)))
            end
        end)
    log('bp', 'disp=' .. tostring(ok1)); _G.P3_BP1 = bp1
    local ok2, bp2 = pcall(PCSX.addBreakpoint, 0x80179BEC, 'Write', 1, 'p3_bec',
        function() log('BEC_WRITE', string.format('val=%d', u8(0x80179BEC))) end)
    log('bp', 'bec=' .. tostring(ok2)); _G.P3_BP2 = bp2
end

local mash_n = 0
local function mash_circle(remaining, next)
    if remaining <= 0 then next(); return end
    mash_n = mash_n + 1
    tap(B.CIRCLE, 12, function()
        shot(string.format('mash%02d', mash_n))
        wait(30, function() mash_circle(remaining - 1, next) end)
    end)
end

local shot_tick = 0
local function phase_followup()
    log('phase', 'followup: hold UP 700f, shot every 60f')
    PAD.setOverride(B.UP)
    local function tick()
        shot_tick = shot_tick + 1
        if shot_tick * 60 >= 700 then
            PAD.clearOverride(B.UP)
            shot('follow_end')
            finish('segment 3 done')
        else
            shot(string.format('up%03d', shot_tick * 60))
            wait(60, tick)
        end
    end
    wait(60, tick)
end

local function phase_walk()
    log('phase', 'walk UP 420f (baseline)')
    PAD.setOverride(B.UP)
    shot('walk_start')
    wait(420, function()
        shot('at_teo')
        wait(60, phase_followup)
    end)
end

local loaded = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    for i = #queue, 1, -1 do
        if queue[i].at <= frame then
            local item = table.remove(queue, i)
            local ok, err = pcall(item.fn)
            if not ok then log('queue_error', tostring(err)) end
        end
    end
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', 'ingame ok=' .. tostring(ok))
        arm()
        shot('loaded')
        wait(60, phase_walk)
    end
    if frame > 7000 then finish('frame budget') end
end)
_G.P3_ANCHOR = vl
_G.P3_PAD = PAD
log('start', 'play3_followup')
