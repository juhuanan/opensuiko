-- mval.lua: log the actual master-mode value seen by AreaSystem_Frame's dispatch.
local ffi = require('ffi')
local bit = require('bit')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/mv.csv'
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
local loaded, done = false, false
local vl
vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    if frame == 60 and not loaded then
        loaded = true
        local f = Support.File.open(START_STATE)
        pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        -- breakpoint at the dispatch lbu (0x800C8B74): log v1 after it executes.
        -- Instead: break at 0x800C8B78 (next insn) and read GPR v1.
        local ok, bp = pcall(PCSX.addBreakpoint, 0x800C8B78, 'Exec', 4, function()
            local ok2, r = pcall(PCSX.getRegisters)
            if ok2 and r then
                local v1 = bit.band(tonumber(r.GPR.n.v1), 0xFFFFFFFF)
                log('dispatch_v1', string.format('%#x lua_u8=%d', v1, u8(0x80179CB8)))
                return false  -- one-shot
            end
        end)
        if ok and bp then ANCH.d = bp else log('bp_fail', 'd') end
        return
    end
    if not loaded then return end
    if frame >= 200 then done = true; logf:close(); PCSX.quit(0) end
end)
_G.MV_ANCHOR = vl
_G.MV_ANCHORS = ANCH
log('start', 'mval')
