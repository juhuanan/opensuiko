-- queuewatch.lua: log the 30-byte master queue during forced load.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/qw/qw.csv'
local OUTDIR = OUT:match('^(.*)/[^/]*$')
os.execute('mkdir -p "' .. OUTDIR .. '"')
local FIXDIR = '/home/hatch/workspace/suikoden/kit/tools/emu/fixtures'
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end

local A_MASTER = 0x80179CB8
local A_PEND, A_FLAG = 0x80179BEC, 0x80179BEB
local A_DISP, A_RES = 0x80179BF4, 0x80179BF3

local frame = 0
local done, loaded = false, false
local phase = 0
local phase_start = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d) logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or ''))); logf:flush() end

local function queue_str()
    local s = {}
    for i = 0, 9 do
        s[#s+1] = string.format('%d', u8(A_MASTER + i))
    end
    return table.concat(s, ',')
end

local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(FIXDIR .. '/ingame.pcsxstate')
        pcall(function() PCSX.loadSaveState(f) end); f:close()
        log('loaded', 'q=' .. queue_str())
        phase = 0; phase_start = frame
        return
    end
    if not loaded then return end
    -- log queue every 30 frames
    if frame % 30 == 0 then
        log('q', string.format('phase=%d q=[%s] res=%d', phase, queue_str(), u8(A_RES)))
    end
    if phase == 0 then
        w8(A_MASTER, 6)
        if u8(A_RES) == 0 then phase = 1; phase_start = frame; log('p0', 'done') end
        if frame - phase_start > 900 then done = true; logf:close(); PCSX.quit(0) end
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
        if frame - phase_start >= 600 then
            done = true; log('done', 'q=' .. queue_str()); logf:close(); PCSX.quit(0)
        end
        return
    end
end)
_G.QW_ANCHOR = vl
log('start', 'queuewatch')
