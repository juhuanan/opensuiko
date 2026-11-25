-- areaload6.lua: full transition_initiator replication + master 1.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/al6/al6.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end

local A_MASTER = 0x80179CB8
local A_PEND, A_FLAG = 0x80179BEC, 0x80179BEB
local A_DISP, A_RES = 0x80179BF4, 0x80179BF3
local A_CURSOR = 0x80179CE8
local A_BF1TAG = 0x80179BF1
local A_TBLVAL = 0x80179C0A
local TBL_BASE = 0x80164E31

local RT_LBA = 0x80164E68
local function res_lba(idx) return u32(RT_LBA + idx * 12) end
local function res_sectors(idx) return bit.band(u32(RT_LBA + idx * 12 + 8), 0xFFFF) end

local frame = 0
local done, loaded = false, false
local phase = 0
local phase_start = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        -- Replicate transition_initiator:
        -- 1. PEND = TARGET
        w8(A_PEND, TARGET)
        -- 2. Table lookup: *(0x80179C0A) = *(0x80164E31 + TARGET*8)
        local tblval = u8(TBL_BASE + TARGET * 8)
        w8(A_TBLVAL, tblval)
        log('loaded', string.format('tblval=%d', tblval))
        phase = 0; phase_start = frame
        return
    end
    if not loaded then return end
    if phase == 0 then
        -- 3. If BF3 != 0: queue master 6 (we do it explicitly)
        w8(A_MASTER, 6)
        if u8(A_RES) == 0 then phase = 1; phase_start = frame; log('p0', 'done') end
        if frame - phase_start > 900 then done = true; logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 1 then
        -- 4. Queue master 2
        w8(A_PEND, TARGET); w8(A_MASTER, 2)
        if u8(A_FLAG) == TARGET then phase = 2; phase_start = frame; log('p1', 'done') end
        if frame - phase_start > 900 then done = true; logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 2 then
        if u8(A_RES) ~= TARGET then w8(A_DISP, TARGET); w8(A_MASTER, 3)
        else phase = 3; phase_start = frame; log('p2', 'done') end
        if frame - phase_start > 900 then done = true; logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 3 then
        local end_lba = res_lba(TARGET) + res_sectors(TARGET)
        if u32(A_CURSOR) >= end_lba then
            phase = 4; phase_start = frame; log('p3', 'stream done')
        end
        if frame - phase_start > 20000 then done = true; logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 4 then
        -- 5. Queue master 1 (activation)
        w8(A_BF1TAG, TARGET)
        w8(A_MASTER, 1)
        phase = 5; phase_start = frame
        log('p4', 'queued master 1')
        return
    end
    if phase == 5 then
        if frame - phase_start >= 600 then
            phase = 6; phase_start = frame
            log('p5', 'done')
            local ok, ss = pcall(PCSX.GPU.takeScreenShot)
            if ok and ss and ss.data then
                local wf = Support.File.open(OUTDIR .. '/after_tbl.raw', 'TRUNCATE')
                if wf then wf:writeMoveSlice(ss.data); wf:close(); log('shot', 'saved') end
            end
        end
        return
    end
    if phase == 6 then
        done = true; log('done', ''); logf:close(); PCSX.quit(0)
    end
end)
_G.AL6_ANCHOR = vl
log('start', 'areaload6 target=' .. TARGET .. ' + table lookup')
