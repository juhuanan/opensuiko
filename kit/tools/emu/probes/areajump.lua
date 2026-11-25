-- areajump.lua v2: drive a PROPER area transition through the game's own
-- state machines. Key insight (static + runtime): the "master mode" byte
-- 0x80179CB8 is the head of a mode queue that a per-frame dequeue
-- (0x800C71B0) shifts whenever nonzero -- so a single write gets stomped.
-- Strategy: re-assert the desired head mode every vsync until its job
-- is done, then stop.
--
-- Phase 1: every vsync: *(0x80179CB8)=1, *(0x80179BEC)=TARGET (kept fresh),
--   sub-mode *(0x80179C02) left alone. Area_RequestNext steps 0->7;
--   mode 7 sets flag *(0x80179BEB)=TARGET. Done when flag==TARGET.
-- Phase 2a: every vsync: *(0x80179CB8)=2, *(0x80179BF4)=TARGET.
--   Dispatcher 0x800C7A24 fires once: copies BF4->BF3, sets up buffers,
--   kicks the loader. Done when *(0x80179BF3)==TARGET (then STOP asserting).
-- Phase 2b: hands off. Common tail of AreaSystem_Frame pumps the 41-state
--   loader (0x800C7E10) while BF3!=0. Watch lstate 0x80179C04.
--   Done when loader idle (lstate==0 for 120f) after having run.
-- Phase 3: settle, screenshot, save state.
--
-- Env: SUIKODEN_TARGET_IDX (default 5 = AREAA_1.8)
--      SUIKODEN_START_STATE (required, valid .pcsxstate)
--      SUIKODEN_SAVE_PATH  (freeze arrived state here; default: none)
--      SUIKODEN_SETTLE     (default 300)
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/areajump.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')
local SAVE_PATH = os.getenv('SUIKODEN_SAVE_PATH')
local SETTLE = tonumber(os.getenv('SUIKODEN_SETTLE') or '300')
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end

local A_MASTER = 0x80179CB8
local A_SUB    = 0x80179C02
local A_PEND   = 0x80179BEC
local A_FLAG   = 0x80179BEB
local A_DISP   = 0x80179BF4
local A_RES    = 0x80179BF3
local A_LSTATE = 0x80179C04
local A_DRIVER = 0x8017DA90

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
    if not ok or not ss or not ss.data then log('shot_fail', tag); return end
    local path = string.format('%s/aj_%03d_%s.raw', SHOTDIR, shot_n, tag)
    local wf = Support.File.open(path, 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/aj_%03d_%s.meta', SHOTDIR, shot_n, tag), 'w')
    if mf then
        mf:write(string.format('width=%s height=%s bpp=%s\n',
            tostring(ss.width), tostring(ss.height), tostring(ss.bpp)))
        mf:close()
    end
    log('shot', tag)
end

local function save_state_ffi(path)
    log('save_state', path)
    local ok, err = pcall(function()
        local ss = PCSX.createSaveState()
        local size = ss.size
        local data = ffi.cast('const char*', ss.data)
        local f = assert(io.open(path, 'wb'))
        local CHUNK = 1024 * 1024
        local offset = 0
        while offset < size do
            local n = math.min(CHUNK, size - offset)
            f:write(ffi.string(data + offset, n))
            offset = offset + n
        end
        f:close()
        log('save_bytes', tostring(size))
    end)
    if not ok then log('save_failed', tostring(err)) end
end

local ANCH = {}
local function arm_cdlog()
    local ok, bp = pcall(PCSX.addBreakpoint, 0x80162FE4, 'Exec', 4, function()
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            local a0 = bit.band(tonumber(r.GPR.n.a0), 0xFFFFFFFF)
            local a1 = bit.band(tonumber(r.GPR.n.a1), 0xFFFFFFFF)
            log('cdread', string.format('dest=%#x count=%#x idx=%d', a0, a1, u8(A_RES)))
        end
    end)
    if ok and bp then ANCH.cd = bp else log('bp_fail', 'cdread') end
    local ok2, bp2 = pcall(PCSX.addBreakpoint, 0x800C7A24, 'Exec', 4, function()
        log('dispatcher', string.format('fired disp_idx=%d', u8(A_DISP)))
    end)
    if ok2 and bp2 then ANCH.disp = bp2 else log('bp_fail', 'dispatcher') end
end

local A_CF8 = 0x80179CF8 -- state-8 gate byte
local function snap()
    return string.format('m=%d sub=%d pend=%d flag=%d disp=%d res=%d ls=%d cf8=%d drv=%#x',
        u8(A_MASTER), u8(A_SUB), u8(A_PEND), u8(A_FLAG),
        u8(A_DISP), u8(A_RES), u8(A_LSTATE), u8(A_CF8), u32(A_DRIVER))
end

local done = false
local loaded = false
local phase = 0
local phase_start = 0
local settle_start = 0
local last_sub, last_ls = -1, -1
local saw_loader_active = false
local idle_since = 0

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1

    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        log('load', tostring(ok))
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
        arm_cdlog()
        log('pre', snap())
        shot('before')
        return
    end
    if not loaded then return end

    if phase == 0 and frame >= 120 then
        phase = 1; phase_start = frame
        log('phase1', snap())
    end

    if phase == 1 then
        -- re-assert every frame: the dequeue stomps a single write.
        -- master 2 = Area_RequestNext (live table; NOT 1)
        w8(A_PEND, TARGET)
        w8(A_MASTER, 2)
        local sub = u8(A_SUB)
        if sub ~= last_sub then
            log('sub', string.format('%d->%d %s', last_sub, sub, snap()))
            last_sub = sub
        end
        if u8(A_FLAG) == TARGET then
            log('phase1_done', snap())
            phase = 2; phase_start = frame
            log('phase2a', snap())
        elseif frame - phase_start > 900 then
            log('phase1_timeout', snap()); shot('p1_timeout')
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end

    if phase == 2 then
        -- 2a: assert head=2 until the dispatcher fires (BF3==TARGET),
        -- then stop asserting and let the loader pump.
        if u8(A_RES) ~= TARGET then
            -- master 3 = area-load dispatcher 0x800C7A24 (live table)
            w8(A_DISP, TARGET)
            w8(A_MASTER, 3)
        else
            log('dispatcher_done', snap())
        end
        local ls = u8(A_LSTATE)
        if ls ~= 0 then saw_loader_active = true; idle_since = frame end
        if ls ~= last_ls then
            log('lstate', string.format('%d->%d %s', last_ls, ls, snap()))
        end
        last_ls = ls
        if saw_loader_active and ls == 0 and frame - idle_since > 120 then
            log('phase2_done', snap())
            shot('arrived')
            phase = 3; settle_start = frame
        elseif frame - phase_start > 3600 then
            log('phase2_timeout', snap()); shot('p2_timeout')
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end

    if phase == 3 then
        if frame - settle_start >= SETTLE then
            log('final', snap())
            shot('final')
            if SAVE_PATH then save_state_ffi(SAVE_PATH) end
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end

    if frame > 12000 then
        log('hard_timeout', snap()); done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.AJ_ANCHOR = vl
_G.AJ_ANCHORS = ANCH
log('start', 'target=' .. TARGET)
