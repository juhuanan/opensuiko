-- areaload3.lua: BF3 fix WITHOUT the extra finalizer at the end.
-- Phase 0: mode 6 until BF3 4->0 (finalize palace)
-- Phase 1: mode 2 until BF1==TARGET (request idx 5)
-- Phase 2: mode 3 until DISP==TARGET (area dispatcher)
-- Phase 3: stream until cursor reaches end (NO finalizer after)
-- Phase 4: settle 600 frames, screenshot, save state.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/al3/al3.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end

local A_MASTER, A_PEND, A_FLAG = 0x80179CB8, 0x80179BEC, 0x80179BEB
local A_DISP, A_RES = 0x80179BF4, 0x80179BF3
local A_CURSOR = 0x80179CE8

local RT_LBA, RT_SECTORS = 0x80164E68, 8
local function res_lba(idx) return u32(RT_LBA + idx * 12) end
local function res_sectors(idx) return bit.band(u32(RT_LBA + idx * 12 + RT_SECTORS), 0xFFFF) end

local frame = 0
local done, loaded = false, false
local phase = 0
local phase_start = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end
local function snap()
    return string.format('res=%d flag=%d disp=%d pend=%d cursor=%d', u8(A_RES), u8(A_FLAG), u8(A_DISP), u8(A_PEND), u32(A_CURSOR))
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', snap())
        phase = 0; phase_start = frame
        return
    end
    if not loaded then return end

    if phase == 0 then
        w8(A_MASTER, 6)
        if u8(A_RES) == 0 then phase = 1; phase_start = frame; log('phase0', 'done ' .. snap()) end
        if frame - phase_start > 900 then done = true; log('timeout', 'p0'); logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 1 then
        w8(A_PEND, TARGET); w8(A_MASTER, 2)
        if u8(A_FLAG) == TARGET then phase = 2; phase_start = frame; log('phase1', 'done ' .. snap()) end
        if frame - phase_start > 900 then done = true; log('timeout', 'p1'); logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 2 then
        if u8(A_RES) ~= TARGET then w8(A_DISP, TARGET); w8(A_MASTER, 3)
        else phase = 3; phase_start = frame; log('phase2', 'done ' .. snap()) end
        if frame - phase_start > 900 then done = true; log('timeout', 'p2'); logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 3 then
        local start_lba, nsec = res_lba(TARGET), res_sectors(TARGET)
        local end_lba = start_lba + nsec
        local cur = u32(A_CURSOR)
        if frame % 300 == 0 then log('stream', string.format('cursor=%d target_end=%d %s', cur, end_lba, snap())) end
        if cur >= end_lba then
            phase = 4; phase_start = frame
            log('phase3', 'stream complete ' .. snap())
        end
        if frame - phase_start > 20000 then done = true; log('timeout', 'p3'); logf:close(); PCSX.quit(0) end
        return
    end
    if phase == 4 then
        -- NO finalizer. Just settle and observe.
        if frame - phase_start >= 600 then
            phase = 5; phase_start = frame
            log('phase4', 'settle done ' .. snap())
            -- dump entries to file for diff
            local f = io.open(OUTDIR .. '/al3_entries.bin', 'wb')
            if f then
                for i = 0, 8191 do
                    f:write(string.char(u8(0x80179F08 + i)))
                end
                f:close()
                log('dump', 'ok')
            else
                log('dump', 'failed')
            end
        end
        return
    end
    if phase == 5 then
        done = true; log('done', snap()); logf:close(); PCSX.quit(0)
    end
end)
_G.AL3_ANCHOR = vl
log('start', 'areaload3 target=' .. TARGET .. ' (no final finalizer)')
