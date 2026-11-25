-- unstuck.lua: test whether a poisoned state has a stuck pad override.
-- Loads state, optionally clears a named button override, then holds another
-- button and screenshots to see if the hero moves.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/unstuck.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local FIXDIR = (os.getenv('SUIKODEN_FIXDIR') or (OUTDIR .. '/fixtures'))
local START_STATE = os.getenv('SUIKODEN_START_STATE') or (FIXDIR .. '/ingame.pcsxstate')
local CLEAR_BTN = os.getenv('SUIKODEN_CLEAR') or ''   -- button to clearOverride after load
local HOLD_BTN  = os.getenv('SUIKODEN_HOLD') or ''    -- button to setOverride
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
    local path = string.format('%s/us_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    log('shot', tag)
end

local done = false
local loaded = false
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok, err = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', string.format('ok=%s', tostring(ok)))
        if CLEAR_BTN ~= '' then
            PAD.clearOverride(B[CLEAR_BTN])
            log('cleared', CLEAR_BTN)
        end
        if HOLD_BTN ~= '' then
            PAD.setOverride(B[HOLD_BTN])
            log('holding', HOLD_BTN)
        end
        shot('start')
    end
    if frame == 300 then shot('t300') end
    if frame == 600 then
        shot('t600')
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.UNSTUCK_ANCHOR = vl
log('start', string.format('clear=%s hold=%s', CLEAR_BTN, HOLD_BTN))
