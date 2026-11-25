-- movecheck.lua: verify hero actually moves with pad input; screenshots + entry-263 tracking.
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/movecheck/movecheck.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON
local function u16(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) + tonumber(RAMB[bit.band(a+1, 0x1FFFFFFF)])*256 end

local frame, done = 0, false
local shot_n = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shotfail', tag); return end
    local path = string.format('%s/mc_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 then
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('load', 'ingame')
        shot('rest')
        return
    end
    if frame == 90 then PAD.setOverride(B.LEFT); log('hold', 'LEFT') return end
    if frame == 210 then
        PAD.clearOverride(B.LEFT)
        shot('after_left')
        log('e263', string.format('v=%d', u16(0x80179F08 + 263*24)))
        PAD.setOverride(B.UP); log('hold', 'UP')
        return
    end
    if frame == 330 then
        PAD.clearOverride(B.UP)
        shot('after_up')
        log('e263', string.format('v=%d', u16(0x80179F08 + 263*24)))
        -- sample entry 50 +8/+16 too
        log('e50', string.format('+8=%d +16lo=%d', u16(0x80179F08+50*24+8), u16(0x80179F08+50*24+16)))
        done = true; logf:close(); PCSX.quit(0)
        return
    end
    if frame > 2000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.MOVECHECK_ANCHOR = vl
log('start', 'movecheck')
