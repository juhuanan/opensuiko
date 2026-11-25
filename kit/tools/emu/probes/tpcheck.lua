-- tpcheck.lua: teleport and monitor the sector window to see if data loads.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/tpcheck.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')
local TARGET = tonumber(os.getenv('SUIKODEN_TARGET_IDX') or '5')

local RAM = ffi.cast('uint32_t *', PCSX.getMemPtr())
local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u32(a) return tonumber(RAM[bit.rshift(bit.band(a, 0x1FFFFFFF), 2)]) end
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end
local function w8(a, v) RAMB[bit.band(a, 0x1FFFFFFF)] = v end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local done = false
local loaded = false
local triggered = false
local last_win = 0
local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; logf:close(); PCSX.quit(0) return end
        last_win = u32(0x80179CE8)
        logf:write(string.format('60,start,win=%08X,idx=%d\n', last_win, u8(0x80179BF3)))
    end
    if loaded and not triggered and frame >= 90 then
        triggered = true
        w8(0x801790B8, TARGET)
        w8(0x80179BF3, TARGET)
        w8(0x80179BEB, 1)
        logf:write(string.format('90,trigger,target=%d\n', TARGET))
        logf:flush()
    end
    if triggered and frame % 30 == 0 then
        local win = u32(0x80179CE8)
        local st = u8(0x80179C04)
        if win ~= last_win then
            logf:write(string.format('%d,win,%08X->%08X,state=%d\n', frame, last_win, win, st))
            logf:flush()
            last_win = win
        end
    end
    if frame >= 600 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.TC_ANCHOR = vl
