-- reload4.lua: try reloading idx 4 (palace, already loaded) to test if the mechanism works.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/r4.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = bit.band(v, 0xFF) end
local TARGET = 4 -- palace (already loaded)
local A_MASTER, A_PEND, A_FLAG, A_DISP, A_RES, A_LSTATE = 0x80179CB8, 0x80179BEC, 0x80179BEB, 0x80179BF4, 0x80179BF3, 0x80179C04
local A_PROG = 0x80179CE8
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local loaded, done, phase, last_ls, last_prog = false, false, 0, -1, -1
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('init', string.format('c90=%d c98=%#x', u8(0x80179C90), u32(0x80179C98)))
        phase = 1
        return
    end
    if not loaded then return end
    if phase == 1 then
        w8(A_PEND, TARGET); w8(A_MASTER, 2)
        if u8(A_FLAG) == TARGET then phase = 2; log('phase', 'req-next done') end
    elseif phase == 2 then
        if u8(A_RES) ~= TARGET then w8(A_DISP, TARGET); w8(A_MASTER, 3)
        else phase = 3; log('phase', 'dispatcher done') end
    else
        local ls, prog = u8(A_LSTATE), u32(A_PROG)
        if ls ~= last_ls or (prog ~= last_prog and bit.band(prog, 0x1FF) == 0) then
            log('lp', string.format('ls=%d prog=%#x', ls, prog))
            last_ls, last_prog = ls, prog
        end
        if ls == 0 and frame > 500 then
            log('done', 'loader idle')
            done = true; logf:close(); PCSX.quit(0)
        end
    end
    if frame >= 5000 then
        log('timeout', string.format('ls=%d prog=%#x', u8(A_LSTATE), u32(A_PROG)))
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.R4_ANCHOR = vl
log('start', 'reload4')
