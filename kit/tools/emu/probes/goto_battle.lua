-- goto_battle.lua: jump to the battle (resource idx 29 = BATTLE1.8).
-- Usage: SUIKODEN_START_STATE=fixtures/ingame.pcsxstate ./run.sh probes/goto_battle.lua <outdir>
-- Saves the arrived state to fixtures/battle.pcsxstate and screenshots.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/gw.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = bit.band(v, 0xFF) end
local TARGET = 29
local A_MASTER, A_PEND, A_FLAG, A_DISP, A_RES, A_LSTATE = 0x80179CB8, 0x80179BEC, 0x80179BEB, 0x80179BF4, 0x80179BF3, 0x80179C04
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local loaded, done, phase, last_ls = false, false, 0, -1
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        phase = 1
        log('phase', 'start target=29 (battle)')
        return
    end
    if not loaded then return end
    if phase == 1 then
        w8(A_PEND, TARGET); w8(A_MASTER, 2) -- Area_RequestNext
        if u8(A_FLAG) == TARGET then phase = 2; log('phase', 'request-next done') end
    elseif phase == 2 then
        if u8(A_RES) ~= TARGET then w8(A_DISP, TARGET); w8(A_MASTER, 3) -- dispatcher
        else phase = 3; log('phase', 'dispatcher done') end
    elseif phase == 3 then
        local ls = u8(A_LSTATE)
        if ls ~= last_ls then log('lstate', string.format('%d->%d', last_ls, ls)); last_ls = ls end
        if ls == 0 and frame > 500 then
            log('phase', 'loader idle - saving')
            local sf = Support.File.open('fixtures/battle.pcsxstate', 'w')
            if sf then pcall(function() PCSX.saveSaveState(sf) end); sf:close()
                log('saved', 'fixtures/battle.pcsxstate') end
            phase = 4
        end
    end
    if frame >= 20000 then
        log('timeout', string.format('ls=%d', u8(A_LSTATE)))
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.GW_ANCHOR = vl
log('start', 'goto_battle')
