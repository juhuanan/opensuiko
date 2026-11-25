-- jumpjal.lua: trigger area-5 load, then watch the state-8/9 jal sites.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/jj.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = bit.band(v, 0xFF) end
local TARGET = 5
local A_MASTER, A_PEND, A_FLAG, A_DISP, A_RES, A_SUB, A_LSTATE = 0x80179CB8, 0x80179BEC, 0x80179BEB, 0x80179BF4, 0x80179BF3, 0x80179C02, 0x80179C04
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local ANCH = {}
local loaded, done, phase = false, false, 0
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        local sites = {
            [0x800C84F8] = 'st8_jal_site', [0x800C8468] = 'st8_worker_entry',
            [0x800C849C] = 'st8_cf8_check', [0x800C84B0] = 'st8_work_path',
            [0x800C850C] = 'st8_skip_path', [0x800C8628] = 'st9_jal_site',
            [0x800C85C4] = 'st9_worker_entry', [0x80162FE4] = 'cdxfer_entry',
            [0x800C8724] = 'setcf8_entry',
        }
        for a, name in pairs(sites) do
            local ok, bp = pcall(PCSX.addBreakpoint, a, 'Exec', 4, function()
                log('hit', string.format('%s ls=%d', name, u8(A_LSTATE)))
            end)
            if ok and bp then ANCH[a] = bp else log('bp_fail', name) end
        end
        phase = 1
        return
    end
    if not loaded then return end
    if phase == 1 then
        w8(A_PEND, TARGET); w8(A_MASTER, 2)
        if u8(A_FLAG) == TARGET then phase = 2; log('phase', '1 done') end
    elseif phase == 2 then
        if u8(A_RES) ~= TARGET then w8(A_DISP, TARGET); w8(A_MASTER, 3)
        else phase = 3; log('phase', '2 done, watching') end
    end
    if frame >= 700 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.JJ_ANCHOR = vl
_G.JJ_ANCHORS = ANCH
log('start', 'jumpjal')
