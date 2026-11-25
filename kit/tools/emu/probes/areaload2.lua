-- areaload2.lua: forced area load with the BF3 fix.
-- The call-graph finding: BF3 must be 0 BEFORE forced-loading. In natural
-- flow, transition_initiator queues master 6 (finalize OLD area) before
-- master 2/3. Skipping that lets the new area's first 0x02xx record trigger
-- a premature mid-stream finalizer via 0x800C87E4.
-- Phase 0: per-frame master=6 until BF3==0 (finalize current area).
-- Phase 1: per-frame *(0x80179BEC)=TARGET, master=2 until BF1==TARGET.
-- Phase 2: per-frame *(0x80179BF4)=TARGET, master=3 until BF3==TARGET.
-- Phase 3: stream N frames; watch for auto-finalizer (c05 steps, BF3->0).
-- Phase 4: per-frame master=6 until BF3==0 (ensure finalization).
-- Phase 5: settle, screenshot, FFI-save state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/al2/al2.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
local SHOTDIR = OUTDIR .. '/shots'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')
local STREAM_FRAMES = tonumber(os.getenv('SUIKODEN_STREAM') or '2000')
local SAVE_PATH = os.getenv('SUIKODEN_SAVE_PATH') or (OUTDIR .. '/worldmap.pcsxstate')
os.execute('mkdir -p "' .. SHOTDIR .. '"')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end

local A_MASTER, A_PEND, A_FLAG = 0x80179CB8, 0x80179BEC, 0x80179BEB
local A_DISP, A_RES = 0x80179BF4, 0x80179BF3
local A_LS, A_CUR, A_C05 = 0x80179C04, 0x80179CE8, 0x80179C05
local A_RESTBL = 0x80164E68

-- end LBA for the target area, from the resource table entry
local function target_end_lba()
    local e = A_RESTBL + TARGET * 12
    local lba = u32(e)
    local cnt = tonumber(bit.band(u32(e + 8), 0xFFFF))
    return lba + cnt, lba, cnt
end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
local function snap()
    return string.format('m=%d bf1=%d bf3=%d bf4=%d ls=%d c05=%d cur=%d',
        u8(A_MASTER), u8(A_FLAG), u8(A_RES), u8(A_DISP), u8(A_LS), u8(A_C05), u32(A_CUR))
end
local function shot(tag)
    local ok, ss = pcall(PCSX.GPU.takeScreenShot)
    if not ok or not ss or not ss.data then return end
    local wf = Support.File.open(string.format('%s/al2_%s.raw', SHOTDIR, tag), 'TRUNCATE')
    wf:writeMoveSlice(ss.data); wf:close()
    local mf = io.open(string.format('%s/al2_%s.meta', SHOTDIR, tag), 'w')
    if mf then mf:write(string.format('width=%s height=%s bpp=%s\n',
        tostring(ss.width), tostring(ss.height), tostring(ss.bpp))); mf:close() end
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

local done, loaded = false, false
local phase = 0
local phase_start = 0
local last_c05 = -1
local last_bf3 = -1
local last_cur_log = 0

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
        last_bf3 = u8(A_RES)
        phase = 0; phase_start = frame
        return
    end
    if not loaded then return end

    -- watch for BF3 / c05 changes in every phase
    local bf3 = u8(A_RES)
    if bf3 ~= last_bf3 then
        log('bf3', string.format('%d->%d %s', last_bf3, bf3, snap()))
        last_bf3 = bf3
    end
    local c05 = u8(A_C05)
    if c05 ~= last_c05 then
        log('c05', string.format('%d->%d %s', last_c05, c05, snap()))
        last_c05 = c05
    end

    if phase == 0 then
        -- FINALIZE CURRENT AREA FIRST (the fix): master 6 until BF3==0, settled.
        -- Once BF3==0, NEVER re-queue 6; just wait for the machine to go idle.
        if not p0_cleared then
            if u8(A_RES) == 0 then
                p0_cleared = true
                log('phase0_bf3zero', snap())
            else
                w8(A_MASTER, 6)
            end
        elseif u8(A_C05) == 0 and u8(A_MASTER) == 0 then
            settle_count = (settle_count or 0) + 1
            if settle_count >= 30 then
                log('phase0_done', 'palace finalized, BF3=0 ' .. snap())
                settle_count = 0
                phase = 1; phase_start = frame
            end
        else
            settle_count = 0
        end
        if frame - phase_start > 1800 then
            log('p0_timeout', snap()); done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
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
            local endlba, lba, cnt = target_end_lba()
            END_LBA = endlba
            log('phase2_done', string.format('%s lba=%d cnt=%d end=%d', snap(), lba, cnt, endlba))
            phase = 3; phase_start = frame
            shot('streaming')
        end
        return
    end
    if phase == 3 then
        if frame - last_cur_log >= 300 then
            last_cur_log = frame
            log('stream', snap())
        end
        local cur = u32(A_CUR)
        if cur >= END_LBA then
            log('stream_done', string.format('cursor reached end %s', snap()))
            shot('pre_final')
            phase = 4; phase_start = frame
        elseif frame - phase_start >= 15000 then
            log('stream_timeout', snap()); shot('stream_timeout')
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
    if phase == 4 then
        -- queue finalizer only until BF3 clears; then let it settle idle
        if not p4_cleared then
            if u8(A_RES) == 0 then
                p4_cleared = true
                log('phase4_bf3zero', snap())
            else
                w8(A_MASTER, 6)
            end
        elseif u8(A_C05) == 0 and u8(A_MASTER) == 0 then
            settle_count = (settle_count or 0) + 1
            if settle_count >= 30 then
                log('BF3_CLEARED_SETTLED', snap())
                shot('finalized')
                phase = 5; phase_start = frame
            end
        else
            settle_count = 0
        end
        if frame - phase_start > 1800 then
            log('p4_timeout', snap()); shot('p4_timeout')
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
    if phase == 5 then
        if frame - phase_start >= 600 then
            log('final', snap()); shot('final')
            save_state_ffi(SAVE_PATH)
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
    if frame > 30000 then
        log('hard_timeout', snap()); done = true; logf:close(); PCSX.quit(0)
    end
end)
_G.AL2_ANCHOR = vl
log('start', string.format('target=%d stream=%d save=%s', TARGET, STREAM_FRAMES, SAVE_PATH))
