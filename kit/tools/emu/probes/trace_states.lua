-- trace_states.lua: trace all state transitions
local ffi = require('ffi')
local OUT = os.getenv('SUIKODEN_OUT') or '/tmp/trace3'
local START_STATE = os.getenv('SUIKODEN_START_STATE')
assert(START_STATE, 'SUIKODEN_START_STATE required')

local RAM = ffi.cast('uint8_t *', PCSX.getMemPtr())
local frame = 0
local state = 0
local done = false

local function rb(addr) return RAM[addr - 0x80000000] end
local function wb(addr, v) RAM[addr - 0x80000000] = v end
local function rw(addr) return ffi.cast('uint32_t *', PCSX.getMemPtr())[ math.floor((addr - 0x80000000) / 4) ] end
local function ww(addr, v) ffi.cast('uint32_t *', PCSX.getMemPtr())[ math.floor((addr - 0x80000000) / 4) ] = v end

-- Breakpoint on state machine dispatcher
local last_sm = -1
local bp_ok = pcall(PCSX.addBreakpoint, 0x800C7E10, 'Exec', 4, 'sm_dispatch', function()
    local sm = rb(0x80179C04)
    if sm ~= last_sm then
        PCSX.log(string.format('trace3: SM -> 0x%02X (RES=%d)', sm, rb(0x80179BF3)))
        last_sm = sm
    end
end)

local vl = PCSX.Events.createEventListener('GPU::Vsync', function()
    if done then return end
    frame = frame + 1
    
    if state == 0 and frame == 60 then
        local f = Support.File.open(START_STATE)
        local ok = pcall(function() PCSX.loadSaveState(f) end)
        f:close()
        if not ok then done = true; PCSX.quit(0) return end
        state = 1
    elseif state == 1 and frame == 120 then
        PCSX.log('trace3: setting CD ready, SM=8, RES=5')
        ww(0x801787C4, 1)
        wb(0x80179C04, 8)
        wb(0x80179BF3, 5)
        state = 2
    elseif state == 2 and frame == 900 then
        PCSX.log(string.format('trace3: done RES=%d SM=0x%02X', rb(0x80179BF3), rb(0x80179C04)))
        done = true
        PCSX.quit(0)
    elseif frame > 1200 then
        done = true
        PCSX.quit(0)
    end
end)
