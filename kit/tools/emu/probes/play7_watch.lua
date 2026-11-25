-- play7_watch.lua: trigger the Teo-lead event, then hands-off observe.
-- UP 420f to approach Teo, then NO INPUT for 2400f, screenshot every 120f.
-- Logs dispatcher tags + BEC writes to catch the transition.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/play7/play7.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
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
    local path = string.format('%s/p7_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/p7_%03d_%s.meta', SHOTDIR, shot_n, tag), 'w')
    if mf then mf:write('width=320 height=240 bpp=BPP_16\n'); mf:close() end
    log('shot', tag)
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
    local ok1, bp1 = pcall(PCSX.addBreakpoint, 0x800C4FE0, 'Exec', 4, 'p7_disp',
        function()
            local ok2, r = pcall(PCSX.getRegisters)
            if ok2 and r then
                log('DISP', string.format('tag=%04x', bit.band(tonumber(r.GPR.n.a0), 0xFFFF)))
            end
        end)
    log('bp', 'disp=' .. tostring(ok1)); _G.P7_BP1 = bp1
    local ok2, bp2 = pcall(PCSX.addBreakpoint, 0x80179BEC, 'Write', 1, 'p7_bec',
        function() log('BEC_WRITE', string.format('val=%d', u8(0x80179BEC))) end)
    log('bp', 'bec=' .. tostring(ok2)); _G.P7_BP2 = bp2
end

local function pos(tag)
    log('pos', string.format('%s y=%d x=%d', tag, u32(0x80172104), u32(0x8017C008)))
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
        log('load', 'ok=' .. tostring(ok))
        arm()
        shot('loaded')
        wait(60, function()
            log('phase', 'UP 420f to trigger Teo event')
            PAD.setOverride(B.UP)
            wait(420, function()
                PAD.clearOverride(B.UP)
                shot('triggered')
                pos('triggered')
                log('phase', 'hands-off observe 2400f')
                local k = 0
                local function tick()
                    k = k + 1
                    shot(string.format('obs%03d', k * 120))
                    pos('obs' .. k)
                    if k >= 20 then
                        finish('observe done')
                    else wait(120, tick) end
                end
                wait(120, tick)
            end)
        end)
    end
    if frame > 12000 then finish('budget') end
end)
_G.P7_ANCHOR = vl
_G.P7_PAD = PAD
log('start', 'play7_watch')
