-- scout.lua
--
-- Reconnaissance: load fixtures/ingame.pcsxstate, screenshot the starting
-- room, hold UP and screenshot periodically to see if/how the hero moves.
-- Also polls MAIN.EXE's loader state byte (0x80179C04) every vsync to learn
-- its idle value and catch any area-load activity.

local ffi = require('ffi')
local bit = require('bit')

local OUT     = os.getenv('SUIKODEN_OUT') or '/tmp/scout.csv'
local FRAMES  = tonumber(os.getenv('SUIKODEN_FRAMES') or '2000')
local OUTDIR  = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR  = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
os.execute('mkdir -p "' .. SHOTDIR .. '"')
local STATE_PATH = FIXDIR .. '/ingame.pcsxstate'

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u32(addr)
    return tonumber(RAM[bit.rshift(bit.band(addr, 0x1FFFFFFF), 2)])
end
local function u8(addr)
    local w = u32(bit.band(addr, 0xFFFFFFFC))
    local s = bit.band(addr, 3) * 8
    return bit.band(bit.rshift(w, s), 0xFF)
end

local LOADER_STATE = 0x80179C04  -- MAIN.EXE 41-state loader state byte

local PAD = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON

local frame = 0
local logf = assert(io.open(OUT, 'w'))
logf:write('frame,event,detail\n')
local function log(event, detail)
    logf:write(string.format('%d,%s,%s\n', frame, event, tostring(detail or '')))
    logf:flush()
end

local shot_n = 0
local function shot(tag)
    shot_n = shot_n + 1
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then log('shot_fail', tag); return end
    local path = string.format('%s/scout_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data)
    wf:close()
    log('shot', string.format('%s state=%d', tag, u8(LOADER_STATE)))
end

local done = false
local function finish(msg)
    if done then return end
    done = true
    log('finish', msg)
    logf:close()
    PCSX.quit(0)
end

local loaded = false
local last_state = -1
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1

    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(STATE_PATH)
        local ok, err = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load_result', string.format('ok=%s err=%s', tostring(ok), tostring(err)))
        if not ok then finish('ABORT: load failed') return end
    end

    if loaded then
        local st = u8(LOADER_STATE)
        if st ~= last_state then
            log('loader_state', string.format('%d->%d', last_state, st))
            last_state = st
        end
    end

    if frame == 180 then shot('room') end
    if frame == 300 then
        log('input', 'holding UP')
        PAD.setOverride(B.UP)
        shot('walk_start')
    end
    if frame == 450 or frame == 600 or frame == 750 or frame == 900
        or frame == 1050 or frame == 1200 then
        shot('walking')
    end
    if frame == 1350 then
        PAD.clearOverride(B.UP)
        log('input', 'released UP')
        shot('walk_end')
    end
    if frame == 1500 then shot('final'); finish('scout done') end
    if frame >= FRAMES then finish('frame budget exhausted') end
end)
_G.SCOUT_ANCHOR = vl
log('start', 'scout running')
