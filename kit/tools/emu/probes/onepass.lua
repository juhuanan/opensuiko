-- onepass.lua: run ONE full pass of the area-5 load, then force ls=0 and save.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/op.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
local SAVE_PATH = os.getenv('SUIKODEN_SAVE_PATH')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMH = ffi.cast('uint16_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function u16(a) return tonumber(RAMH[bit.rshift(bit.band(a, 0x1FFFFFFF), 1)]) end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = bit.band(v, 0xFF) end
local TARGET = 5
local A_MASTER, A_PEND, A_FLAG, A_DISP, A_RES, A_LSTATE = 0x80179CB8, 0x80179BEC, 0x80179BEB, 0x80179BF4, 0x80179BF3, 0x80179C04
local A_PROG = 0x80179CE8
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local loaded, done, phase = false, false, 0
local END_LBA = 0
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        local e = 0x80164E68 + TARGET * 12
        END_LBA = u32(e) + u16(e + 8)
        log('init', string.format('end_lba=%#x', END_LBA))
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
    elseif phase == 3 then
        local prog = u32(A_PROG)
        if prog >= END_LBA then
            log('phase', string.format('one pass complete prog=%#x, forcing ls=0', prog))
            w8(A_LSTATE, 0)
            phase = 4
        end
    elseif phase == 4 then
        -- let it settle for 120 frames, then save
        if frame % 120 == 0 then
            log('settle', string.format('ls=%d', u8(A_LSTATE)))
        end
        if u8(A_LSTATE) == 0 then
            -- count 120 frames of ls=0
            if not _G.OP_SETTLE then _G.OP_SETTLE = frame end
            if frame - _G.OP_SETTLE > 120 then
                log('saving', SAVE_PATH or 'none')
                if SAVE_PATH then
                    local sf = Support.File.open(SAVE_PATH, 'w')
                    if sf then pcall(function() PCSX.saveSaveState(sf) end); sf:close()
                        log('saved', SAVE_PATH) end
                end
                done = true; logf:close(); PCSX.quit(0)
            end
        else
            _G.OP_SETTLE = nil
        end
    end
    if frame >= 20000 then
        log('timeout', string.format('prog=%#x', u32(A_PROG)))
        done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.OP_ANCHOR = vl
log('start', 'onepass')
