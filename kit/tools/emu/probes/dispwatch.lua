-- dispwatch.lua: watch tag_dispatcher(0x800C4FE0) calls during forced load.
-- Logs distinct tags seen, focusing on 0x02xx record tags.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/dw/dw.csv'
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

local logf = assert(io.open(OUT, 'w'))
local frame = 0
local done, loaded = false, false
local phase = 0
local phase_start = 0
local seen_tags = {}
local disp_hits = 0
local MAX_HITS = 500
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

-- exec breakpoint on tag_dispatcher; armed after state load. Read a0 via getRegisters.
local function arm_disp_bp()
    local bp_ok, bp = pcall(PCSX.addBreakpoint, 0x800C4FE0, 'Exec', 4, 'tag_dispatcher', function()
        if disp_hits >= MAX_HITS then return end
        disp_hits = disp_hits + 1
        local ok2, r = pcall(PCSX.getRegisters)
        local tag = 0xFFFF
        if ok2 and r then
            tag = bit.band(tonumber(r.GPR.n.a0), 0xFFFF)
        end
        seen_tags[tag] = (seen_tags[tag] or 0) + 1
        if disp_hits <= 60 or bit.band(tag, 0xFF00) == 0x0200 then
            log('disp', string.format('tag=%04x count=%d phase=%d', tag, seen_tags[tag], phase))
        end
    end)
    if not bp_ok then log('bp_fail', 'dispatcher') else log('bp_ok', 'dispatcher armed') end
    _G.DW_BP = bp
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', 'bf3=' .. u8(A_RES))
        arm_disp_bp()
        phase = 0; phase_start = frame
        return
    end
    if not loaded then return end
    if phase == 0 then
        w8(A_MASTER, 6)
        if u8(A_RES) == 0 then phase = 1; phase_start = frame; log('p0', 'done') end
        if frame - phase_start > 900 then phase = 1; phase_start = frame end
        return
    end
    if phase == 1 then
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
        -- stream for a while, watching dispatcher
        if frame - phase_start >= 1200 then
            phase = 4
            log('summary', 'distinct tags:')
            for t, c in pairs(seen_tags) do
                log('tagsum', string.format('%04x x%d', t, c))
            end
            done = true; logf:close(); PCSX.quit(0)
        end
        return
    end
end)
_G.DW_ANCHOR = vl
log('start', 'dispwatch target=' .. TARGET)
