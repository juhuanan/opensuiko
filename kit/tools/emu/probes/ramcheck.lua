-- ramcheck.lua: force area-5 load for N frames, then check if AREAA_1.8 data is in RAM.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/rc.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local RAMW = ffi.cast('uint32_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function u32(a) return tonumber(RAMW[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = bit.band(v, 0xFF) end
local TARGET = 5
local A_MASTER, A_PEND, A_FLAG, A_DISP, A_RES = 0x80179CB8, 0x80179BEC, 0x80179BEB, 0x80179BF4, 0x80179BF3
local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end
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
        phase = 1
        return
    end
    if not loaded then return end
    if phase == 1 then
        w8(A_PEND, TARGET); w8(A_MASTER, 2)
        if u8(A_FLAG) == TARGET then phase = 2 end
    elseif phase == 2 then
        if u8(A_RES) ~= TARGET then w8(A_DISP, TARGET); w8(A_MASTER, 3)
        else phase = 3; log('phase', 'loading...') end
    elseif phase == 3 and frame == 3000 then
        -- check RAM for AREAA_1.8 signature
        -- The .8 file starts with 16-byte records; check the load buffer
        -- Loader dest is around 0x801F0000? Actually check sector table at 0x800C98F0
        local tbl = u32(0x80179DD0)
        log('tbl', string.format('tbl_base=%#x', tbl))
        -- dump first 32 bytes at tbl base
        local parts = {}
        for i = 0, 31 do
            parts[#parts+1] = string.format('%02x', u8(tbl + i))
        end
        log('data', table.concat(parts, ' '))
        -- Also check 0x801F0000 (streaming buffer) for comparison
        parts = {}
        for i = 0, 31 do
            parts[#parts+1] = string.format('%02x', u8(0x801F0000 + i))
        end
        log('stream', table.concat(parts, ' '))
        done = true; logf:close(); PCSX.quit(0)
    end
    if frame >= 4000 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.RC_ANCHOR = vl
log('start', 'ramcheck')
