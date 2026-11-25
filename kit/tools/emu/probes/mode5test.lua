-- mode5test.lua: forced area load + mode-5 finalizer test.
-- Phase 1: drive Area_RequestNext (mode 2) until flag set.
-- Phase 2: drive dispatcher (mode 3) until BF3==TARGET.
-- Phase 3: let loader stream for N frames, then set master head=5 (post-load).
-- Watch: does BF3 clear? does 0x80179C05 step? does display update?
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/m5t.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')
local STREAM_FRAMES = tonumber(os.getenv('SUIKODEN_STREAM') or '1500')
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end

local A_MASTER, A_PEND, A_FLAG = 0x80179CB8, 0x80179BEC, 0x80179BEB
local A_DISP, A_RES = 0x80179BF4, 0x80179BF3
local A_LS, A_CUR, A_C05 = 0x80179C04, 0x80179CE8, 0x80179C05

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local function snap()
    return string.format('m=%d bf3=%d ls=%d c05=%d cur=%d',
        u8(A_MASTER), u8(A_RES), u8(A_LS), u8(A_C05), u32(A_CUR))
end
local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local wf = Support.File.open(string.format('%s/m5_%s.raw', SHOTDIR, tag), 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/m5_%s.meta', SHOTDIR, tag), 'w')
    if mf then mf:write(string.format('width=%s height=%s bpp=%s\n',
        tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
    log('shot', tag)
end

local done, loaded = false, false
local phase = 0
local phase_start = 0
local last_c05 = -1

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('loaded', snap())
        phase = 1; phase_start = frame
        return
    end
    if not loaded then return end

    if phase == 1 then
        w8(A_PEND, TARGET); w8(A_MASTER, 2)
        if u8(A_FLAG) == TARGET then
            log('phase1_done', snap()); phase = 2; phase_start = frame
        elseif frame - phase_start > 900 then
            log('p1_timeout', snap()); done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
    if phase == 2 then
        if u8(A_RES) ~= TARGET then
            w8(A_DISP, TARGET); w8(A_MASTER, 3)
        else
            log('phase2_done', snap()); phase = 3; phase_start = frame
            shot('streaming')
        end
        return
    end
    if phase == 3 then
        -- let it stream, then hit it with mode 5
        if frame - phase_start >= STREAM_FRAMES then
            log('mode5_go', snap())
            shot('pre_mode5')
            phase = 4; phase_start = frame
        end
        return
    end
    if phase == 4 then
        w8(A_MASTER, 6)  -- post-load finalizer 0x800C881C, re-assert (queue may shift)
        local c05 = u8(A_C05)
        if c05 ~= last_c05 then
            log('c05', string.format('%d->%d %s', last_c05, c05, snap()))
            last_c05 = c05
        end
        if u8(A_RES) == 0 then
            log('BF3_CLEARED', snap())
            shot('finalized')
            phase = 5; phase_start = frame
        elseif frame - phase_start > 1800 then
            log('mode5_timeout', snap()); shot('m5_timeout')
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
    if phase == 5 then
        -- settle, watch for display change
        if frame - phase_start >= 600 then
            log('final', snap()); shot('final')
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
    if frame > 20000 then
        log('hard_timeout', snap()); done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.M5_ANCHOR = vl
log('start', string.format('target=%d stream=%d', TARGET, STREAM_FRAMES))
