-- masterwatch.lua: who writes the area-system master mode byte 0x80179CB8?
-- Load ingame state, arm a Write breakpoint, log PC/RA + value for 600 frames.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/mw.csv'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAMB = ffi.cast('uint8_t *', PCSX.getMemPtr())
local function u8(a) return tonumber(RAMB[bit.band(a, 0x1FFFFFFF)]) end

local frame = 0
local logf = assert(io.open(OUT, 'w'))
local function log(e, d)
    logf:write(string.format('%d,%s,%s\n', frame, e, tostring(d or '')))
    logf:flush()
end

local ANCH = {}
local loaded = false
local done = false

local function arm()
    local ok, bp = pcall(PCSX.addBreakpoint, 0x80179CB8, 'Write', 1, function(addr, width)
        local ok2, r = pcall(PCSX.getRegisters)
        if ok2 and r then
            local pc = bit.band(tonumber(r.pc), 0xFFFFFFFF)
            local ra = bit.band(tonumber(r.GPR.n.ra), 0xFFFFFFFF)
            log('write', string.format('pc=%#x ra=%#x old=%d', pc, ra, u8(0x80179CB8)))
        else
            log('write', 'noreg')
        end
    end)
    if ok and bp then ANCH.w = bp; log('armed', 'ok') else log('armed', 'FAIL') end
end

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
        arm()
        return
    end
    if not loaded then return end
    if frame == 90 then
        -- also try writing master=1 once and see who stomps it
        local RAMW8 = ffi.cast('uint8_t *', PCSX.getMemPtr())
        RAMW8[bit.band(0x80179CB8, 0x1FFFFFFF)] = 1
        log('poke', 'master=1')
    end
    if frame >= 700 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.MW_ANCHOR = vl
_G.MW_ANCHORS = ANCH
log('start', 'masterwatch')
